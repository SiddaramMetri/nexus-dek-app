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

    public var id: String { "\(pid)-\(port)" }

    public init(pid: Int32, command: String, user: String, port: Int, proto: String,
                cpu: Double? = nil, memoryBytes: UInt64? = nil) {
        self.pid = pid
        self.command = command
        self.user = user
        self.port = port
        self.proto = proto
        self.cpu = cpu
        self.memoryBytes = memoryBytes
    }

    /// pid 0/1 (kernel, launchd) — never killable.
    public var isSystem: Bool { pid < 2 }
}

/// Ports backend: lsof field mode + ps enrichment, and the kill path.
public enum Ports {
    // MARK: - List

    /// Listening ports (or every TCP connection). lsof/ps exit non-zero when
    /// nothing matches, so their stdout is read regardless of status.
    public static func list(listeningOnly: Bool) async -> [PortInfo] {
        let rows = dedup(Parsers.lsofFields(await Proc.anyOutput("lsof", lsofArgs(listeningOnly: listeningOnly))))
        let ids = pidList(rows)
        let samples = ids.isEmpty ? [:] : Parsers.ps(await Proc.anyOutput("ps", ["-o", "pid=,%cpu=,rss=,etime=", "-p", ids]))
        return enrich(rows, samples: samples)
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
                            cpu: s?.cpu, memoryBytes: s?.rssBytes)
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
