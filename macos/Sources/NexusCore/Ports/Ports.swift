import Darwin
import Foundation

/// One TCP port + its owning process, enriched with cpu/mem.
public struct PortInfo: Identifiable, Equatable, Hashable, Sendable {
    public var pid: Int32
    public var command: String
    public var user: String
    public var port: Int
    public var proto: String
    public var cpu: Double?
    public var memoryBytes: UInt64?
    public var uptimeSecs: UInt64?
    public var ppid: Int32?
    /// Full command line as ps prints it (argv joined by spaces).
    public var commandLine: String?
    public var executablePath: String?
    public var cwd: String?
    public var owner: PortOwner = .other
    /// "Next.js", "Django", … from the command line.
    public var framework: String?

    public var id: String { "\(pid)-\(port)" }

    public init(pid: Int32, command: String, user: String, port: Int, proto: String,
                cpu: Double? = nil, memoryBytes: UInt64? = nil, uptimeSecs: UInt64? = nil,
                ppid: Int32? = nil, commandLine: String? = nil, executablePath: String? = nil,
                cwd: String? = nil, owner: PortOwner = .other, framework: String? = nil) {
        self.pid = pid
        self.command = command
        self.user = user
        self.port = port
        self.proto = proto
        self.cpu = cpu
        self.memoryBytes = memoryBytes
        self.uptimeSecs = uptimeSecs
        self.ppid = ppid
        self.commandLine = commandLine
        self.executablePath = executablePath
        self.cwd = cwd
        self.owner = owner
        self.framework = framework
    }

    /// `http://localhost:PORT`.
    public var localURL: URL? { URL(string: "http://localhost:\(port)") }

    /// pid 0/1 (kernel, launchd) — never killable.
    public var isSystem: Bool { pid < 2 }
}

/// Ports backend: lsof field mode + ps enrichment, and the kill path.
public enum Ports {
    // MARK: - List

    /// Listening ports (or every TCP connection), each classified by owner.
    public static func list(listeningOnly: Bool) async -> [PortInfo] {
        await snapshot(listeningOnly: listeningOnly).ports
    }

    /// Ports plus the git branch of every project they belong to. Three
    /// subprocesses per refresh, all batched: lsof (listeners), ps (stats +
    /// command lines), lsof (cwds). lsof/ps exit non-zero when nothing
    /// matches, so their stdout is read regardless of status.
    public static func snapshot(listeningOnly: Bool, home: URL = Paths.home) async -> PortsSnapshot {
        let rows = dedup(Parsers.lsofFields(await Proc.anyOutput("lsof", lsofArgs(listeningOnly: listeningOnly))))
        let ids = pidList(rows)
        guard !ids.isEmpty else { return PortsSnapshot(ports: [], branches: [:]) }
        async let psOut = Proc.anyOutput("ps", ["-o", "pid=,ppid=,%cpu=,rss=,etime=,command=", "-p", ids])
        async let cwdOut = Proc.anyOutput("lsof", ["-a", "-p", ids, "-d", "cwd", "-Fpn"])
        let procs = processes(await psOut)
        let cwds = Self.cwds(await cwdOut)
        var exePaths: [Int32: String] = [:]
        for pid in Set(rows.map(\.pid)) { exePaths[pid] = PortClassifier.executablePath(pid: pid) }
        let ports = classify(enrich(rows, samples: procs.mapValues(\.sample)), procs: procs, cwds: cwds,
                             exePaths: exePaths, home: home)
        var branches: [String: String] = [:]
        var declared: [String: [DeclaredServer]] = [:]
        for case let .project(root) in Set(ports.map(\.owner)) {
            branches[root] = GitHead.branch(atRoot: root)
            declared[root] = ProjectServers.discover(root: root)
        }
        return PortsSnapshot(ports: ports, branches: branches, declared: declared)
    }

    /// Fill in command line, cwd, executable, owner and framework.
    static func classify(_ ports: [PortInfo], procs: [Int32: PsProcess], cwds: [Int32: String],
                         exePaths: [Int32: String], home: URL) -> [PortInfo] {
        var owners: [Int32: PortOwner] = [:]
        return ports.map { p in
            var p = p
            let proc = procs[p.pid]
            p.ppid = proc?.ppid
            p.commandLine = proc?.command
            p.cwd = cwds[p.pid]
            // proc_pidpath fails for some root processes; argv[0] is the fallback.
            p.executablePath = exePaths[p.pid] ?? proc.flatMap { cmd in
                cmd.command.split(whereSeparator: \.isWhitespace).first.map(String.init).flatMap { $0.hasPrefix("/") ? $0 : nil }
            }
            if let owner = owners[p.pid] {
                p.owner = owner
            } else {
                p.owner = PortClassifier.classify(executable: p.executablePath, cwd: p.cwd,
                                                  commandLine: p.commandLine, home: home)
                owners[p.pid] = p.owner
            }
            p.framework = p.commandLine.flatMap(PortFramework.detect(commandLine:))
            return p
        }
    }

    /// One `ps -o pid=,ppid=,%cpu=,rss=,etime=,command=` row.
    struct PsProcess: Equatable, Sendable {
        var ppid: Int32
        var sample: Parsers.PsSample
        var command: String
    }

    static func processes(_ out: String) -> [Int32: PsProcess] {
        var map: [Int32: PsProcess] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let f = line.split(maxSplits: 5, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard f.count >= 5, let pid = Int32(f[0]), let ppid = Int32(f[1]), let cpu = Double(f[2]),
                  let rss = UInt64(f[3]), let up = Parsers.etime(String(f[4])) else { continue }
            let command = f.count > 5 ? f[5].trimmingCharacters(in: .whitespaces) : ""
            map[pid] = PsProcess(ppid: ppid, sample: Parsers.PsSample(cpu: cpu, rssBytes: rss * 1024, uptimeSecs: up),
                                 command: command)
        }
        return map
    }

    /// `lsof -a -p … -d cwd -Fpn` → pid → working directory.
    static func cwds(_ out: String) -> [Int32: String] {
        var map: [Int32: String] = [:]
        var pid: Int32 = 0
        for line in out.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            if tag == "p" { pid = Int32(line.dropFirst()) ?? 0 }
            if tag == "n", pid > 0 { map[pid] = String(line.dropFirst()) }
        }
        return map
    }

    static func lsofArgs(listeningOnly: Bool) -> [String] {
        listeningOnly ? ["-nP", "-iTCP", "-FpcLtn", "-sTCP:LISTEN"] : ["-nP", "-iTCP", "-FpcLtn"]
    }

    /// Merge IPv4/IPv6 duplicates of the same (pid, port); first one wins.
    static func dedup(_ rows: [Parsers.LsofRow]) -> [Parsers.LsofRow] {
        var seen = Set<String>()
        return rows.filter { seen.insert("\($0.pid):\($0.port)").inserted }
    }

    /// Sorted, unique pids as `ps -p` wants them.
    static func pidList(_ rows: [Parsers.LsofRow]) -> String {
        Set(rows.map(\.pid)).sorted().map(String.init).joined(separator: ",")
    }

    static func enrich(_ rows: [Parsers.LsofRow], samples: [Int32: Parsers.PsSample]) -> [PortInfo] {
        rows.map { r in
            let s = samples[r.pid]
            return PortInfo(pid: r.pid, command: r.command, user: r.user, port: r.port, proto: r.proto,
                            cpu: s?.cpu, memoryBytes: s?.rssBytes, uptimeSecs: s?.uptimeSecs)
        }
    }

    // MARK: - Kill

    /// EPERM from kill(2) — the one `forbidden` the UI answers with the admin prompt
    /// (the pid guards are `forbidden` too, but escalating can't help those).
    public static let permissionDenied = AppError.forbidden("permission denied (needs admin)")

    /// SIGTERM (or SIGKILL when `force`). `sudo` escalates via the native admin
    /// prompt. Guards: never signal pid < 2 (kernel/launchd) or this app.
    public static func kill(pid: Int32, force: Bool, sudo: Bool) async throws {
        try guardTarget(pid: pid, selfPid: getpid())
        if sudo {
            let out = try await Proc.run("/usr/bin/osascript", ["-e", adminScript(pid: pid, force: force)])
            guard !out.ok else { return }
            let err = out.err.trimmingCharacters(in: .whitespacesAndNewlines)
            // -128 = the user dismissed the admin prompt — nothing changed.
            if err.contains("(-128)") { throw AppError.userCancelled }
            throw AppError.shell(err.isEmpty ? "osascript failed" : err)
        }
        if Darwin.kill(pid, force ? SIGKILL : SIGTERM) == 0 { return }
        let code = errno
        if code == EPERM { throw permissionDenied }
        throw AppError.io("kill failed: \(String(cString: strerror(code)))")
    }

    static func guardTarget(pid: Int32, selfPid: Int32) throws {
        if pid < 2 { throw AppError.forbidden("refusing to signal pid < 2") }
        if pid == selfPid { throw AppError.forbidden("refusing to kill Nexus Console") }
    }

    /// Whitelisted admin command — only a fixed signal name and an Int32 pid
    /// (already guarded) are interpolated, so there's no injection surface.
    /// Review as security code.
    static func adminScript(pid: Int32, force: Bool) -> String {
        let sig = force ? "KILL" : "TERM"
        return "do shell script \"/bin/kill -\(sig) \(pid)\" with administrator privileges"
    }

    /// Stop every server process of a project after one native confirm.
    /// SIGTERM each pid; failures are collected so one stubborn process
    /// doesn't leave the rest running.
    public static func stopProject(name: String, ports: [PortInfo], confirmer: Confirmer) async throws {
        let pids = Array(Set(ports.map(\.pid))).sorted()
        guard !pids.isEmpty else { return }
        let names = Array(Set(ports.map(\.command))).sorted().joined(separator: ", ")
        let list = ports.map { ":\($0.port)" }.sorted().joined(separator: ", ")
        try await confirmer.require(
            title: "Stop \(name)?",
            message: "Sends SIGTERM to \(pids.count) process\(pids.count == 1 ? "" : "es") (\(names)) "
                + "listening on \(list). Unsaved work in those servers may be lost.",
            action: "Stop project", destructive: true)
        var failures: [String] = []
        for pid in pids {
            do { try await kill(pid: pid, force: false, sudo: false) } catch {
                failures.append("pid \(pid): \(AppError.from(error).message)")
            }
        }
        if !failures.isEmpty { throw AppError.io("Couldn't stop all of \(name) — " + failures.joined(separator: "; ")) }
    }

    // MARK: - View-model helpers

    /// Matches command, port, pid or user (case-insensitive substring).
    public static func filter(_ ports: [PortInfo], query: String) -> [PortInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return ports }
        return ports.filter {
            $0.command.lowercased().contains(q) || String($0.port).contains(q)
                || String($0.pid).contains(q) || $0.user.lowercased().contains(q)
        }
    }
}
