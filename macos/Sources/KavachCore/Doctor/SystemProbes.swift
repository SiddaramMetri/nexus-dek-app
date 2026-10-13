import Foundation

// Seed probes (disk_free, load_vs_cores — syscall-only, sub-ms) plus the four
// high-signal macOS System Health probes: low_power_mode, memory_truth,
// backup_risk, startup_items. All read-only reads of Apple's own tools;
// nothing here wakes a daemon or mutates state. Parsers are pure for tests.
public enum SystemProbes {
    public static let diskFree = Probe(id: "disk_free", scope: .disk) { await runDiskFree() }
    public static let loadVsCores = Probe(id: "load_vs_cores", scope: .system) { await runLoadVsCores() }
    public static let lowPowerMode = Probe(id: "low_power_mode", scope: .system) { await runLowPower() }
    public static let memoryTruth = Probe(id: "memory_truth", scope: .system) { await runMemoryTruth() }
    public static let backupRisk = Probe(id: "backup_risk", scope: .system) { await runBackupRisk() }
    public static let startupItems = Probe(id: "startup_items", scope: .startup) { await runStartupItems() }

    // MARK: - disk_free

    static let diskRedGB = 10.0
    static let diskYellowGB = 30.0
    static let gb = 1e9 // decimal GB, matching what Finder shows

    static func classifyDisk(_ freeBytes: UInt64) -> Severity {
        let gb = Double(freeBytes) / gb
        return gb < diskRedGB ? .red : gb < diskYellowGB ? .yellow : .green
    }

    static func runDiskFree() async -> [Finding] {
        guard let free = diskFreeBytes() else { return [diskFree.failed(tag: .storage, "read free disk space")] }
        let severity = classifyDisk(free)
        let explain = severity == .green
            ? "Plenty of headroom."
            : "Below ~\(Int(diskYellowGB)) GB free, macOS starts struggling — swap, caches and updates all need "
            + "headroom. Deep scan (dev caches, node_modules) is where the reclaimable space usually hides."
        return [Finding(probeId: diskFree.id, scope: diskFree.scope, severity: severity, tag: .storage,
                        summary: String(format: "%.0f GB free on /", Double(free) / gb), explain: explain)]
    }

    static func diskFreeBytes() -> UInt64? {
        var vfs = statvfs()
        guard statvfs("/", &vfs) == 0 else { return nil }
        return UInt64(vfs.f_bavail) * UInt64(vfs.f_frsize)
    }

    // MARK: - load_vs_cores

    static func classifyLoad(_ load5: Double, cores: Int) -> Severity {
        let c = Double(cores)
        return load5 >= c * 2 ? .red : load5 >= c ? .yellow : .green
    }

    static func runLoadVsCores() async -> [Finding] {
        guard let load5 = loadAvg5min() else { return [loadVsCores.failed(tag: .speed, "read the load average")] }
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let severity = classifyLoad(load5, cores: cores)
        let load = String(format: "%.1f", load5)
        let explain = severity == .green
            ? "The CPU is keeping up — no processes are queueing."
            : "5-minute load \(load) on \(cores) cores: sustained load above the core count means processes are "
            + "queueing for CPU. Open Activity Monitor → CPU to find the top consumer (a boot-time Spotlight "
            + "re-index is transient and settles on its own)."
        return [Finding(probeId: loadVsCores.id, scope: loadVsCores.scope, severity: severity, tag: .speed,
                        summary: "Load \(load) over 5 min on \(cores) cores", explain: explain)]
    }

    /// 5-minute average — the "sustained" signal; 1-minute spikes are noise.
    static func loadAvg5min() -> Double? {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads[1] : nil
    }

    // MARK: - low_power_mode

    static func parseLowPower(_ pmset: String) -> Bool? {
        guard let line = pmset.split(whereSeparator: \.isNewline).first(where: { $0.contains("lowpowermode") }),
              let last = line.split(whereSeparator: \.isWhitespace).last else { return nil }
        return last == "1"
    }

    static func runLowPower() async -> [Finding] {
        guard let out = await Proc.output("pmset", ["-g"]) else {
            return [lowPowerMode.failed(tag: .speed, "read power settings (pmset)")]
        }
        // Key absent (e.g. older desktop Macs) → feature not present, never renders.
        guard let on = parseLowPower(out) else { return [] }
        let p = lowPowerMode
        if on {
            return [Finding(
                probeId: p.id, scope: p.scope, severity: .red, tag: .speed,
                summary: "Low Power Mode is ON — the CPU is being throttled",
                explain: "Low Power Mode saves battery BY slowing the CPU down. If this machine feels slow, turn "
                    + "this off first — it was the measured root cause of the original \"my Mac is slow\" case.",
                guide: ["Open System Settings → Battery", "Set Low Power Mode to \"Never\" or \"Only on Battery\""])]
        }
        return [Finding(probeId: p.id, scope: p.scope, severity: .green, tag: .speed,
                        summary: "Low Power Mode is off", explain: "The CPU runs at full speed.")]
    }

    // MARK: - memory_truth

    static let swapYellowMB = 2048.0

    /// "total = 2048.00M  used = 512.00M  free = 1536.00M  (encrypted)"
    static func parseSwapUsedMB(_ s: String) -> Double? {
        guard let r = s.range(of: "used =") else { return nil }
        let num = s[r.upperBound...].drop { $0.isWhitespace }.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        return Double(num)
    }

    /// Kernel pressure level: 1 = normal, 2 = warning, 4 = critical.
    static func classifyMemory(level: UInt32, swapMB: Double) -> Severity {
        if level >= 4 { return .red }
        if level >= 2 || swapMB > swapYellowMB { return .yellow }
        return .green
    }

    static func runMemoryTruth() async -> [Finding] {
        async let levelOut = Proc.output("sysctl", ["-n", "kern.memorystatus_vm_pressure_level"])
        async let swapOut = Proc.output("sysctl", ["-n", "vm.swapusage"])
        let level = await levelOut.flatMap { UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let swap = await swapOut.flatMap(parseSwapUsedMB)
        guard let level, let swapMB = swap else {
            return [memoryTruth.failed(tag: .speed, "read memory pressure (sysctl)")]
        }
        let severity = classifyMemory(level: level, swapMB: swapMB)
        let label = level >= 4 ? "critical" : level >= 2 ? "warning" : "normal"
        let swapText = String(format: "%.0f", swapMB)
        let explain: String
        switch severity {
        case .green:
            explain = "\"Free\" RAM near zero is NORMAL on macOS — the honest signals are swap and the kernel "
                + "pressure level, and both look fine."
        case .yellow where level < 2:
            explain = "Swap usage is high (\(swapText) MB). If it keeps growing, something is leaking memory or "
                + "the machine is over capacity — check Activity Monitor → Memory."
        default:
            explain = "The kernel is under memory pressure — apps are (or will start) swapping to disk and "
                + "everything feels slower. Close the heaviest apps (Activity Monitor → Memory)."
        }
        return [Finding(probeId: memoryTruth.id, scope: memoryTruth.scope, severity: severity, tag: .speed,
                        summary: "Memory pressure \(label) · swap \(swapText) MB used", explain: explain)]
    }

    // MARK: - backup_risk

    static func parseTMName(_ s: String) -> String? {
        guard let line = s.split(whereSeparator: \.isNewline).first(where: {
            $0.drop { $0.isWhitespace }.hasPrefix("Name")
        }) else { return nil }
        let parts = line.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return nil }
        let name = parts[1].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    static func runBackupRisk() async -> [Finding] {
        // stdout+stderr regardless of exit code — tmutil "fails" when
        // unconfigured, which is exactly the state we want to detect.
        guard let r = try? await Proc.run("tmutil", ["destinationinfo"]) else {
            return [backupRisk.failed(tag: .info, "read Time Machine status (tmutil)")]
        }
        let out = r.out + r.err
        let p = backupRisk
        if out.contains("No destinations configured") {
            return [Finding(
                probeId: p.id, scope: p.scope, severity: .yellow, tag: .info,
                summary: "No Time Machine backup configured",
                explain: "Nothing on this machine is backed up — one disk failure loses everything. Any external "
                    + "disk works as a destination.",
                guide: ["Open System Settings → General → Time Machine", "Add a backup destination"])]
        }
        if let name = parseTMName(out) {
            return [Finding(probeId: p.id, scope: p.scope, severity: .green, tag: .info,
                            summary: "Time Machine configured → \(name)", explain: "A backup destination is set up.")]
        }
        // Fail-safe: unrecognized output shape → say so, never guess.
        return [p.failed(tag: .info, "parse Time Machine status")]
    }

    // MARK: - startup_items

    /// Launch agents that watch folders even when nothing uses them.
    static let noisyAgents = ["watchman"]
    static let maxListed = 12

    /// `launchctl list` → "PID\tStatus\tLabel"; third-party = label not com.apple.*.
    static func parseThirdPartyLabels(_ s: String) -> [String] {
        s.split(whereSeparator: \.isNewline).dropFirst()
            .compactMap { line -> String? in
                let cols = line.split(whereSeparator: \.isWhitespace)
                return cols.count > 2 ? String(cols[2]) : nil
            }
            .filter { !$0.hasPrefix("com.apple.") }
    }

    static func runStartupItems() async -> [Finding] {
        // launchctl list is read-only — it reports loaded jobs, never starts one.
        guard let out = await Proc.output("launchctl", ["list"]) else {
            return [startupItems.failed(tag: .speed, "list launch agents (launchctl)")]
        }
        let p = startupItems
        let labels = parseThirdPartyLabels(out)
        if labels.isEmpty {
            return [Finding(probeId: p.id, scope: p.scope, severity: .green, tag: .speed,
                            summary: "No third-party launch agents", explain: "Nothing extra loads at login.")]
        }
        let noisy = labels.contains { l in noisyAgents.contains { l.lowercased().contains($0) } }
        var listed = labels.prefix(maxListed).joined(separator: ", ")
        if labels.count > maxListed { listed += ", … +\(labels.count - maxListed)" }
        var explain = "Loaded at login, each costs some CPU/RAM: \(listed). Review anything you don't recognize."
        if noisy {
            explain += " watchman watches project folders even when no tool uses it (jest here runs with watchman "
                + "disabled) — `brew uninstall watchman` if nothing needs it."
        }
        let s = labels.count == 1 ? "" : "s"
        return [Finding(
            probeId: p.id, scope: p.scope, severity: noisy ? .yellow : .green, tag: .speed,
            summary: "\(labels.count) third-party launch agent\(s) running\(noisy ? " — watchman detected" : "")",
            explain: explain)]
    }
}
