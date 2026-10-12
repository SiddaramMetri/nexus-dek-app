import Foundation

// Browser Doctor — the measured recipes from the original session:
//   browser_processes — per running Chromium browser: total RSS + the
//     extension share (the A/B-measured 1.38 GB lesson). Grouping is by FULL
//     args, never the truncated comm (the multi-word-name bug).
//   browser_audio — "Playing audio" power assertions: block IDLE sleep only,
//     lid-close always sleeps (the expectation-correcting lesson).
//   browser_storage — cache size (one-click clear) + background mode.
//   browser_extensions — see BrowserExtensions.swift.
// Read-only: `ps`, `pmset`, `du` and file reads; nothing is woken.
public enum BrowserProbes {
    public static let processes = Probe(id: "browser_processes", scope: .browser,
                                        available: anyInstalled) { await runProcesses() }
    public static let audioBlocker = Probe(id: "browser_audio", scope: .browser,
                                           available: anyInstalled) { await runAudio() }
    public static let storage = Probe(id: "browser_storage", scope: .browser,
                                      available: anyInstalled) { await runStorage() }

    struct Browser: Sendable {
        let label: String
        /// Full-args match marker for ps grouping.
        let marker: String
        let app: String
        /// ~/Library/Caches/<this> — safe to clear when the browser is closed.
        let cacheRel: String
        /// ~/Library/Application Support/<this> — profiles + Local State live here.
        let supportRel: String

        var installed: Bool { DoctorSupport.isDir(URL(fileURLWithPath: app)) }
        var cacheDir: URL { Paths.home.appendingPathComponent("Library/Caches/" + cacheRel, isDirectory: true) }
        var supportDir: URL {
            Paths.home.appendingPathComponent("Library/Application Support/" + supportRel, isDirectory: true)
        }
        var localState: URL { supportDir.appendingPathComponent("Local State") }
        func running(_ ps: String) -> Bool { parsePS(ps, marker: marker).procs > 0 }
    }

    /// Brave/Edge are the same Chromium probes, purely data-driven.
    static let browsers: [Browser] = [
        Browser(label: "Chrome", marker: "Google Chrome.app", app: "/Applications/Google Chrome.app",
                cacheRel: "Google/Chrome", supportRel: "Google/Chrome"),
        Browser(label: "Brave", marker: "Brave Browser.app", app: "/Applications/Brave Browser.app",
                cacheRel: "BraveSoftware/Brave-Browser", supportRel: "BraveSoftware/Brave-Browser"),
        Browser(label: "Edge", marker: "Microsoft Edge.app", app: "/Applications/Microsoft Edge.app",
                cacheRel: "Microsoft Edge", supportRel: "Microsoft Edge"),
    ]

    static func browser(_ label: String) -> Browser? { browsers.first { $0.label == label } }

    static let anyInstalled: @Sendable () -> Bool = { browsers.contains { $0.installed } }

    // MARK: - browser_processes

    /// Extensions above this share of RSS get the yellow + guide.
    static let extYellowBytes: UInt64 = 500 * 1024 * 1024

    struct Stats: Equatable {
        var procs = 0, totalKB: UInt64 = 0, extProcs = 0, extKB: UInt64 = 0
        var rendererKB: UInt64 = 0, gpuKB: UInt64 = 0
    }

    /// `ps -Ao rss=,args=` lines → per-browser split. Full-args matching only.
    static func parsePS(_ ps: String, marker: String) -> Stats {
        var s = Stats()
        for raw in ps.split(whereSeparator: \.isNewline) {
            let line = raw.drop { $0.isWhitespace }
            guard let sp = line.firstIndex(of: " "), let rss = UInt64(line[..<sp]) else { continue }
            let args = line[line.index(after: sp)...]
            guard args.contains(marker) else { continue }
            s.procs += 1
            s.totalKB += rss
            if args.contains("--extension-process") {
                s.extProcs += 1
                s.extKB += rss
            } else if args.contains("--type=renderer") {
                s.rendererKB += rss
            } else if args.contains("--type=gpu-process") {
                s.gpuKB += rss
            }
        }
        return s
    }

    static func runProcesses() async -> [Finding] {
        guard let ps = await Proc.output("ps", ["-Ao", "rss=,args="]) else {
            return [processes.failed(tag: .speed, "list processes (ps)")]
        }
        let p = processes
        var out: [Finding] = []
        for b in browsers where b.installed {
            let s = parsePS(ps, marker: b.marker)
            if s.procs == 0 {
                out.append(Finding(probeId: p.id, scope: p.scope, severity: .green, tag: .speed,
                                   summary: "\(b.label) is not running", explain: "No processes, no memory."))
                continue
            }
            let extBytes = s.extKB * 1024
            let heavy = extBytes > extYellowBytes
            let ext = s.extProcs > 0 ? " · extensions \(DoctorSupport.mb(extBytes)) (\(s.extProcs))" : ""
            out.append(Finding(
                probeId: p.id, scope: p.scope, severity: heavy ? .yellow : .green, tag: .speed,
                summary: "\(b.label) · \(DoctorSupport.mb(s.totalKB * 1024)) across \(s.procs) processes\(ext)",
                explain: "Renderers \(DoctorSupport.mb(s.rendererKB * 1024)) · GPU \(DoctorSupport.mb(s.gpuKB * 1024)) "
                    + "— many processes is NORMAL (site isolation); the total tracks how many tabs you keep open. "
                    + "Extensions run their own processes: disabling unused ones measurably freed 1.38 GB in the "
                    + "original case.",
                guide: heavy ? [
                    "\(b.label): open the extensions page and disable what you don't use",
                    "Ground truth per tab/extension: Shift+Esc opens the browser's own task manager",
                ] : nil))
        }
        return out
    }

    // MARK: - browser_audio

    /// "Playing audio" assertion owners, e.g. `pid 435(Google Chrome): … Playing audio`.
    static func parseAudioOwners(_ pmset: String) -> [String] {
        let names = pmset.split(whereSeparator: \.isNewline)
            .filter { $0.contains("Playing audio") }
            .compactMap { line -> String? in
                guard let pid = line.range(of: "pid ") else { return nil }
                let rest = line[pid.upperBound...]
                guard let open = rest.firstIndex(of: "("), let close = rest.firstIndex(of: ")"),
                      open < close else { return nil }
                return String(rest[rest.index(after: open)..<close])
            }
        return Array(Set(names)).sorted()
    }

    static func runAudio() async -> [Finding] {
        guard let out = await Proc.output("pmset", ["-g", "assertions"]) else {
            return [audioBlocker.failed(tag: .info, "read power assertions (pmset)")]
        }
        let p = audioBlocker
        let owners = parseAudioOwners(out)
        if owners.isEmpty {
            return [Finding(probeId: p.id, scope: p.scope, severity: .green, tag: .info,
                            summary: "Nothing is holding an audio sleep assertion",
                            explain: "No app is keeping the Mac awake for audio.")]
        }
        return [Finding(
            probeId: p.id, scope: p.scope, severity: .yellow, tag: .info,
            summary: "Playing audio — idle sleep blocked by \(owners.joined(separator: ", "))",
            explain: "An audio assertion only blocks IDLE sleep — closing the lid always sleeps. Usually a tab "
                + "playing (or having played) sound.",
            guide: ["Find the tab: Shift+Esc in the browser (its own task manager), or look for the speaker icon on tabs"])]
    }

    // MARK: - browser_storage

    /// Caches worth a line above this floor.
    static let cacheMinBytes: UInt64 = 100 * 1024 * 1024

    /// Local State JSON → is "continue running background apps" enabled?
    /// Unrecognized shape → nil (never guessed).
    static func parseBackgroundMode(_ raw: String) -> Bool? {
        guard let v = DoctorSupport.jsonObject(raw), let bg = v["background_mode"] as? [String: Any] else { return nil }
        return DoctorSupport.jsonBool(bg["enabled"])
    }

    static func runStorage() async -> [Finding] {
        let p = storage
        var out: [Finding] = []
        for b in browsers where b.installed {
            if Task.isCancelled { break }
            // Cache size — one-click clear, gated on the browser being closed.
            if DoctorSupport.isDir(b.cacheDir) {
                let bytes = await DoctorSupport.duBytes(b.cacheDir)
                if bytes >= cacheMinBytes {
                    out.append(Finding(
                        probeId: p.id, scope: p.scope, severity: .yellow, tag: .storage,
                        summary: "\(b.label) cache · \(DoctorSupport.mb(bytes)) reclaimable",
                        explain: "Pure web cache — it re-downloads as you browse. Clearing frees disk (first page "
                            + "loads may be briefly slower); the browser must be closed while it's cleared.",
                        fix: "browser_cache:\(b.label)"))
                }
            }
            // Background mode — keeps helper processes alive after the window closes.
            let raw = try? String(contentsOf: b.localState, encoding: .utf8)
            if raw.flatMap(parseBackgroundMode) == true {
                out.append(Finding(
                    probeId: p.id, scope: p.scope, severity: .yellow, tag: .speed,
                    summary: "\(b.label) keeps running in the background when closed",
                    explain: "\"Continue running background apps\" keeps browser processes (and extension "
                        + "background pages) alive after you close the window — quietly costing memory and battery.",
                    guide: ["\(b.label): Settings → System → turn OFF \"Continue running background apps when "
                        + "\(b.label) is closed\""]))
            }
        }
        if out.isEmpty {
            out.append(Finding(
                probeId: p.id, scope: p.scope, severity: .green, tag: .storage,
                summary: "Browser caches are small · no background mode",
                explain: "Nothing above the 100 MB noise floor, and no browser keeps running after its window closes."))
        }
        return out
    }

    // MARK: - Fixes

    /// Native-confirm copy for a cache clear.
    static func fixConfirmation(_ label: String) -> (title: String, message: String) {
        ("Clear the \(label) cache?",
         "The browser must be closed. The cache re-downloads as you browse — this frees disk but does not make "
            + "the machine faster.")
    }

    /// Clear a browser's disk cache. Label validated against the static table;
    /// refuses while that browser is running (its own gate, like VACUUM).
    static func clearCache(_ label: String) async throws -> String {
        guard let b = browser(label), b.installed else { throw AppError.notFound("no such browser: \(label)") }
        let ps = await Proc.output("ps", ["-Ao", "rss=,args="]) ?? ""
        if b.running(ps) { throw AppError.forbidden("Close \(label) first — its cache is in use.") }
        guard DoctorSupport.isDir(b.cacheDir) else { throw AppError.notFound("\(label) cache is already empty") }
        let bytes = await DoctorSupport.duBytes(b.cacheDir)
        do { try FileManager.default.removeItem(at: b.cacheDir) } catch { throw AppError.io(error.localizedDescription) }
        Journal.write(action: "clearBrowserCache", ["browser": label, "freedBytes": bytes])
        return "Cleared the \(label) cache · freed \(DoctorSupport.mb(bytes)) — it re-downloads as you browse"
    }
}
