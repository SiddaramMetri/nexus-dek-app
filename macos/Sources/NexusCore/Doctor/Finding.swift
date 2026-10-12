import Foundation

/// Scan scopes — mirror the Doctor page's scope chips 1:1.
public enum Scope: String, Codable, CaseIterable, Sendable {
    case system, claude, vscode, browser, disk, startup
}

/// Declared in report order — red first.
public enum Severity: Int, Codable, Comparable, Sendable {
    case red = 0, yellow, green
    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    public var name: String { switch self { case .red: "red"; case .yellow: "yellow"; case .green: "green" } }
}

/// Honest tag: disk cleanup does NOT make a machine faster. `info` is for
/// findings that are neither (backup risk, battery wear).
public enum Tag: String, Codable, Sendable { case speed, storage, info }

/// One line in the report. `guide` = manual GUI steps; `fix` = id of an
/// automated fix the UI maps to a button (the UI never supplies paths).
public struct Finding: Equatable, Identifiable, Sendable {
    public var id: String { "\(probeId)|\(summary)" }
    public var probeId: String
    public var scope: Scope
    public var severity: Severity
    public var tag: Tag
    public var summary: String
    public var explain: String
    public var guide: [String]?
    public var fix: String?

    public init(probeId: String, scope: Scope, severity: Severity, tag: Tag,
                summary: String, explain: String, guide: [String]? = nil, fix: String? = nil) {
        self.probeId = probeId
        self.scope = scope
        self.severity = severity
        self.tag = tag
        self.summary = summary
        self.explain = explain
        self.guide = guide
        self.fix = fix
    }
}

/// A read-only health probe. Must not wake daemons or block on anything
/// interactive; mutations only ever happen through explicit fix functions.
public struct Probe: Sendable {
    public let id: String
    public let scope: Scope
    /// Runtime capability check — a feature this Mac doesn't have never renders.
    public let available: @Sendable () -> Bool
    public let run: @Sendable () async -> [Finding]

    public init(id: String, scope: Scope, available: @escaping @Sendable () -> Bool = { true },
                run: @escaping @Sendable () async -> [Finding]) {
        self.id = id
        self.scope = scope
        self.available = available
        self.run = run
    }

    /// A probe that can't read its source says so instead of silently vanishing.
    public func failed(tag: Tag, _ what: String) -> Finding {
        Finding(probeId: id, scope: scope, severity: .yellow, tag: tag,
                summary: "Couldn't \(what)",
                explain: "The read-only probe failed on this machine — the item was not checked.")
    }
}
