import Foundation

/// Parsers for system tool output. Pure functions, fixture-tested.
public enum Parsers {
    /// `launchctl list` → formula → pid, for `homebrew.mxcl.*` labels with a numeric PID.
    public static func launchctl(_ out: String) -> [String: Int32] {
        var map: [String: Int32] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let f = line.split(whereSeparator: \.isWhitespace)
            guard f.count >= 3, let pid = Int32(f[0]) else { continue }
            let label = f[2]
            if label.hasPrefix("homebrew.mxcl.") {
                map[String(label.dropFirst("homebrew.mxcl.".count))] = pid
            }
        }
        return map
    }

    /// `lsof -nP -iTCP -sTCP:LISTEN -a -p <pids>` → pid → first listening port.
    public static func listeningPorts(_ out: String) -> [Int32: Int] {
        var map: [Int32: Int] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let f = line.split(whereSeparator: \.isWhitespace)
            guard f.count >= 9, let pid = Int32(f[1]) else { continue }
            if let port = portAfterColon(f[8]), map[pid] == nil { map[pid] = port }
        }
        return map
    }

    public struct LsofRow: Equatable, Sendable {
        public var pid: Int32
        public var command: String
        public var user: String
        public var proto: String
        public var port: Int
    }

    /// `lsof -nP -iTCP -FpcLtn` field mode: one row per `n` line.
    public static func lsofFields(_ out: String) -> [LsofRow] {
        var rows: [LsofRow] = []
        var pid: Int32 = 0
        var command = "", user = "", proto = ""
        for line in out.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let val = line.dropFirst()
            switch tag {
            case "p": pid = Int32(val) ?? 0
            case "c": command = String(val)
            case "L": user = String(val)
            case "t": proto = String(val)
            case "n":
                if let port = portAfterColon(val) {
                    rows.append(LsofRow(pid: pid, command: command, user: user, proto: proto, port: port))
                }
            default: break
            }
        }
        return rows
    }

    static func portAfterColon<S: StringProtocol>(_ s: S) -> Int? {
        guard let idx = s.lastIndex(of: ":") else { return Int(s).flatMap { $0 <= 65535 ? $0 : nil } }
        guard let p = Int(s[s.index(after: idx)...]), (0...65535).contains(p) else { return nil }
        return p
    }

    public struct PsSample: Equatable, Sendable {
        public var cpu: Double
        public var rssBytes: UInt64
        public var uptimeSecs: UInt64
    }

    /// `ps -o pid=,%cpu=,rss=,etime=` → pid → sample. rss is KiB.
    public static func ps(_ out: String) -> [Int32: PsSample] {
        var map: [Int32: PsSample] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let f = line.split(whereSeparator: \.isWhitespace)
            guard f.count >= 4, let pid = Int32(f[0]), let cpu = Double(f[1]), let rss = UInt64(f[2]),
                  let up = etime(String(f[3])) else { continue }
            map[pid] = PsSample(cpu: cpu, rssBytes: rss * 1024, uptimeSecs: up)
        }
        return map
    }

    /// `MM:SS` | `HH:MM:SS` | `DD-HH:MM:SS` → seconds.
    public static func etime(_ s: String) -> UInt64? {
        var days: UInt64 = 0
        var hms = Substring(s)
        if let dash = s.firstIndex(of: "-") {
            guard let d = UInt64(s[..<dash]) else { return nil }
            days = d
            hms = s[s.index(after: dash)...]
        }
        let parts = hms.split(separator: ":", omittingEmptySubsequences: false).map { UInt64($0) }
        guard !parts.contains(where: { $0 == nil }) else { return nil }
        let p = parts.compactMap { $0 }
        let (h, m, sec): (UInt64, UInt64, UInt64)
        switch p.count {
        case 2: (h, m, sec) = (0, p[0], p[1])
        case 3: (h, m, sec) = (p[0], p[1], p[2])
        default: return nil
        }
        return ((days * 24 + h) * 60 + m) * 60 + sec
    }

    /// StandardOutPath out of a homebrew `homebrew.mxcl.*.plist`.
    public static func logPath(fromPlist plist: String) -> String? {
        guard let at = plist.range(of: "StandardOutPath") else { return nil }
        let after = plist[at.upperBound...]
        guard let open = after.range(of: "<string>") else { return nil }
        let rest = after[open.upperBound...]
        guard let close = rest.range(of: "</string>") else { return nil }
        return rest[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
