import NexusCore
import Observation

/// Ports tab data. Outlives the page view so returning to the tab (or flipping
/// Listening/All) keeps the previous list on screen while the next one loads —
/// no flash back to the skeleton.
@MainActor @Observable
final class PortsStore {
    static let shared = PortsStore()

    var listeningOnly = true
    private(set) var rows: [PortInfo]?
    private var inFlight = 0

    var isFetching: Bool { inFlight > 0 }

    func reload() async {
        let scope = listeningOnly
        inFlight += 1
        defer { inFlight -= 1 }
        let list = await Ports.list(listeningOnly: scope)
        // Drop a result for a scope the user already switched away from.
        if scope == listeningOnly { rows = list }
    }

    /// The kill sheet is the confirmation; the list refreshes either way.
    func kill(_ target: PortInfo, force: Bool, sudo: Bool) async throws {
        defer { Task { await reload() } }
        try await Ports.kill(pid: target.pid, force: force, sudo: sudo)
    }
}
