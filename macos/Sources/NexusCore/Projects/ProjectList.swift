import Foundation

public enum ProjectFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All", running = "Running", unsaved = "Unsaved work", pinned = "Pinned"
    public var id: String { rawValue }
}

public enum ProjectSort: String, CaseIterable, Identifiable, Sendable {
    case recent = "Recent activity", name = "Name", removable = "Removable size"
    public var id: String { rawValue }
}

/// What the Projects tab knows about each project beyond discovery, keyed by root.
public struct ProjectFacts: Equatable, Sendable {
    /// Roots with at least one live port.
    public var running: Set<String> = []
    /// Roots whose git status has uncommitted changes or unpushed commits.
    public var unsaved: Set<String> = []
    public var pinned: Set<String> = []
    /// Removable bytes from the last Dev cleanup scan.
    public var removable: [String: UInt64] = [:]

    public init(running: Set<String> = [], unsaved: Set<String> = [], pinned: Set<String> = [],
                removable: [String: UInt64] = [:]) {
        self.running = running
        self.unsaved = unsaved
        self.pinned = pinned
        self.removable = removable
    }
}

/// Search, filter and sort for the Projects tab, plus the bridge to the Ports
/// tab's card model. Pure.
public enum ProjectList {
    public static let pins = JSONStore<[String]>(file: "projects.json", key: "pinned")

    /// Matching projects, pinned first, then by `sort`.
    public static func arrange(_ projects: [ProjectInfo], query: String, filter: ProjectFilter, sort: ProjectSort,
                               facts: ProjectFacts, home: String = Paths.home.path) -> [ProjectInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = projects.filter { p in
            let passes = switch filter {
            case .all: true
            case .running: facts.running.contains(p.root)
            case .unsaved: facts.unsaved.contains(p.root)
            case .pinned: facts.pinned.contains(p.root)
            }
            return passes && (q.isEmpty || matches(p, query: q, home: home))
        }
        return shown.sorted { a, b in
            let pa = facts.pinned.contains(a.root), pb = facts.pinned.contains(b.root)
            if pa != pb { return pa }
            switch sort {
            case .recent:
                if a.lastActivityEpoch != b.lastActivityEpoch { return a.lastActivityEpoch > b.lastActivityEpoch }
            case .removable:
                let ra = facts.removable[a.root] ?? 0, rb = facts.removable[b.root] ?? 0
                if ra != rb { return ra > rb }
                if a.lastActivityEpoch != b.lastActivityEpoch { return a.lastActivityEpoch > b.lastActivityEpoch }
            case .name:
                break
            }
            let byName = a.name.localizedStandardCompare(b.name)
            return byName == .orderedSame ? a.root < b.root : byName == .orderedAscending
        }
    }

    /// Name, or the path as shown (`~/code/api`) or in full. `query` is lowercased.
    static func matches(_ p: ProjectInfo, query q: String, home: String) -> Bool {
        p.name.lowercased().contains(q)
            || PortSections.abbreviate(p.root, home: home).lowercased().contains(q)
            || p.root.lowercased().contains(q)
    }

    /// Live ports by the project root that owns them.
    public static func portsByRoot(_ ports: [PortInfo]) -> [String: [PortInfo]] {
        var out: [String: [PortInfo]] = [:]
        for p in ports {
            if case let .project(root) = p.owner { out[root, default: []].append(p) }
        }
        return out
    }

    /// The project as a Ports-tab card model: declared servers matched to its
    /// live ports, frontend first, plus its whole-stack launcher.
    public static func group(for p: ProjectInfo, ports: [PortInfo], branch: String?,
                             home: String = Paths.home.path) -> PortGroup {
        let mine = ports.filter { $0.owner == .project(root: p.root) }.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
        var g = PortGroup(kind: .project, key: p.root, title: p.name, subtitle: PortSections.abbreviate(p.root, home: home),
                          branch: branch, brewService: nil, ports: mine)
        g.servers = PortSections.slots(declared: p.declared.filter { !$0.isLauncher }, running: mine)
        g.launcher = p.declared.first { $0.isLauncher && $0.dir == p.root } ?? p.declared.first(where: \.isLauncher)
        return g
    }
}
