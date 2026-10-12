import Foundation

public enum DisplayStatus: String, Sendable {
    case running, starting, stopping, stopped, error, notInstalled
}

/// A managed service enriched with live brew data — what the Services tab renders.
public struct ReconciledService: Equatable, Identifiable, Sendable {
    public var id: String { formula }
    public var formula: String
    public var displayName: String
    public var status: DisplayStatus
    public var linkState: LinkState
    public var pid: Int32?
    public var cpu: Double?
    public var memoryBytes: UInt64?
    public var uptimeSecs: UInt64?
    public var port: Int?
    public var healthy: Bool?
    public var plist: String?
}

public enum Reconcile {
    /// brew status × health → display status. A started-but-unreachable
    /// service is `starting`, not green.
    public static func status(_ s: ServiceInfo?) -> DisplayStatus {
        guard let s else { return .notInstalled }
        switch s.status {
        case "started": return s.healthy == false ? .starting : .running
        case "stopping": return .stopping
        case "error": return .error
        default: return .stopped
        }
    }

    /// Merge the managed registry (+ intent) with live brew data, keyed on the
    /// bare name (a service added from search is tap-qualified; brew reports it bare).
    public static func merge(
        managed: [ManagedService], brew: [ServiceInfo], intent: [String: LinkState]
    ) -> [ReconciledService] {
        var byName: [String: ServiceInfo] = [:]
        for s in brew { byName[bareFormula(s.name)] = s }
        return managed.map { m in
            let s = byName[bareFormula(m.formula)]
            return ReconciledService(
                formula: m.formula, displayName: m.displayName, status: status(s),
                linkState: intent[m.formula] ?? .unlinked,
                pid: s?.pid, cpu: s?.cpu, memoryBytes: s?.memoryBytes, uptimeSecs: s?.uptimeSecs,
                port: s?.port, healthy: s?.healthy, plist: s?.plist)
        }
    }
}
