import Foundation
import NexusCore
import Observation

/// State for the Projects tab. App-wide so the discovered list, git statuses
/// and toolbar choices survive switching tabs.
@MainActor @Observable
final class ProjectsModel {
    static let shared = ProjectsModel()

    /// A refresh on appear only when the list is older than this.
    static let staleAfter: TimeInterval = 60
    static let gitConcurrency = 4

    private(set) var projects: [ProjectInfo] = []
    private(set) var loadedAt: Date?
    private(set) var loading = false
    var query = ""
    /// Opens on Running; falls back to All once, if nothing is running.
    var filter: ProjectFilter = .running {
        didSet { if !applyingDefault { userPickedFilter = true } }
    }
    private var userPickedFilter = false
    private var applyingDefault = false

    /// Called after each load: if the user hasn't chosen a filter and nothing
    /// runs, show everything instead of an empty Running view.
    func settleDefaultFilter(runningCount: Int) {
        guard !userPickedFilter else { return }
        applyingDefault = true
        filter = runningCount > 0 ? .running : .all
        applyingDefault = false
    }
    var sort: ProjectSort = .recent
    private(set) var pinned: Set<String>
    /// Git status per root for the current refresh (nil value = not a repo, or git failed).
    private(set) var git: [String: GitSafety.Status?] = [:]

    private var gitQueue: [String] = []
    private var gitInFlight: Set<String> = []
    /// Bumped per refresh so statuses from an older list are dropped.
    private var generation = 0

    init() {
        pinned = Set(ProjectList.pins.load() ?? [])
    }

    // MARK: - Derived

    var gitPending: Int { gitQueue.count + gitInFlight.count }

    /// Live ports, unsaved work, pins and Dev cleanup sizes, keyed by root.
    var facts: ProjectFacts {
        let byRoot = ProjectList.portsByRoot(PortsStore.shared.snapshot?.ports ?? [])
        var removable: [String: UInt64] = [:]
        for item in CleanupModel.shared.items where !item.locked {
            if let b = item.bytes { removable[item.groupRoot, default: 0] += b }
        }
        let unsaved = git.compactMap { root, status in status?.hasUnsavedWork == true ? root : nil }
        return ProjectFacts(running: Set(byRoot.keys), unsaved: Set(unsaved), pinned: pinned, removable: removable)
    }

    func shown(_ facts: ProjectFacts) -> [ProjectInfo] {
        ProjectList.arrange(projects, query: query, filter: filter, sort: sort, facts: facts)
    }

    // MARK: - Discovery

    func refreshIfStale() async {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < Self.staleAfter { return }
        await refresh()
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        // Instant first paint from the saved index; the full walk below
        // then adds new projects and drops removed ones.
        if projects.isEmpty {
            let cached = ProjectDiscovery.cachedRoots()
            if !cached.isEmpty { projects = await ProjectDiscovery.infos(roots: cached) }
        }
        // Port owners join the list even when they aren't git repositories.
        if PortsStore.shared.snapshot == nil { await PortsStore.shared.reload() }
        let owners = Array(ProjectList.portsByRoot(PortsStore.shared.snapshot?.ports ?? []).keys)
        projects = await ProjectDiscovery.discover(extraRoots: owners)
        loadedAt = Date()
        generation += 1
        git = [:]
        gitQueue = []
        gitInFlight = []
        settleDefaultFilter(runningCount: ProjectList.portsByRoot(PortsStore.shared.snapshot?.ports ?? []).count)
        if filter == .unsaved { requestAllGit() }
    }

    /// Adds projects that started serving a port since the last refresh.
    func adopt(portOwners roots: [String]) {
        guard loadedAt != nil else { return }
        let known = Set(projects.map(\.root))
        let fresh = roots.filter { !known.contains($0) }
        guard !fresh.isEmpty else { return }
        Task {
            let infos = await Task.detached { fresh.map(ProjectDiscovery.info(root:)) }.value
            let known = Set(projects.map(\.root))
            projects += infos.filter { !known.contains($0.root) }
        }
    }

    // MARK: - Git status (lazy, a few at a time)

    func requestGit(_ root: String) {
        guard git[root] == nil, !gitInFlight.contains(root), !gitQueue.contains(root) else { return }
        gitQueue.append(root)
        pump()
    }

    /// The "Unsaved work" filter needs every project's status.
    func requestAllGit() {
        for p in projects { requestGit(p.root) }
    }

    private func pump() {
        while gitInFlight.count < Self.gitConcurrency, !gitQueue.isEmpty {
            let root = gitQueue.removeFirst()
            let gen = generation
            gitInFlight.insert(root)
            Task {
                let status = await GitSafety.status(root)
                guard gen == generation else { return }
                gitInFlight.remove(root)
                git[root] = .some(status)
                pump()
            }
        }
    }

    // MARK: - Pins

    func togglePin(_ root: String) {
        if pinned.contains(root) { pinned.remove(root) } else { pinned.insert(root) }
        ProjectList.pins.save(pinned.sorted())
    }
}
