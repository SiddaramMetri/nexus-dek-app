import NexusCore
import Observation

/// Ports tab data. Outlives the page view so returning to the tab (or flipping
/// Listening/All) keeps the previous list on screen while the next one loads —
/// no flash back to the skeleton. Section expansion lives here for the same reason.
@MainActor @Observable
final class PortsStore {
    static let shared = PortsStore()

    enum Section: String, CaseIterable, Identifiable {
        case projects, apps, system, other
        var id: String { rawValue }

        var title: String {
            switch self {
            case .projects: "Your projects"
            case .apps: "Apps"
            case .system: "macOS"
            case .other: "Other"
            }
        }
    }

    var listeningOnly = true
    var expanded: Set<Section> = [.projects, .other]
    private(set) var snapshot: PortsSnapshot?
    private var inFlight = 0

    var isFetching: Bool { inFlight > 0 }

    func reload() async {
        let scope = listeningOnly
        inFlight += 1
        defer { inFlight -= 1 }
        let next = await Ports.snapshot(listeningOnly: scope)
        // Drop a result for a scope the user already switched away from.
        if scope == listeningOnly { snapshot = next }
    }

    func toggle(_ section: Section) {
        if expanded.contains(section) { expanded.remove(section) } else { expanded.insert(section) }
    }

    /// The kill sheet is the confirmation; the list refreshes either way.
    func kill(_ target: PortInfo, force: Bool, sudo: Bool) async throws {
        defer { Task { await reload() } }
        try await Ports.kill(pid: target.pid, force: force, sudo: sudo)
    }

    /// Confirms natively inside NexusCore, then SIGTERMs every pid.
    func stopProject(_ group: PortGroup, confirmer: Confirmer) async throws {
        defer { Task { await reload() } }
        try await Ports.stopProject(name: group.title, ports: group.ports, confirmer: confirmer)
    }
}
