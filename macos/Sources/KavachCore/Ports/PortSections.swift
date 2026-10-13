import Foundation

/// One refresh worth of ports, plus the git branch of each project root.
public struct PortsSnapshot: Equatable, Sendable {
    public var ports: [PortInfo]
    public var branches: [String: String]
    /// Dev servers each project declares (package.json scripts, manage.py).
    public var declared: [String: [DeclaredServer]]

    public init(ports: [PortInfo], branches: [String: String], declared: [String: [DeclaredServer]] = [:]) {
        self.ports = ports
        self.branches = branches
        self.declared = declared
    }
}

/// One server on a project card: a declared server (running or not), or a
/// running process the project doesn't declare.
public struct ServerSlot: Identifiable, Equatable, Sendable {
    public let declared: DeclaredServer?
    /// Its listening ports (empty = not running).
    public let running: [PortInfo]
    public let role: ServerRole

    public var id: String { declared?.id ?? "pid:\(running.first?.pid ?? 0)" }
    /// Display name override (a tool's name, e.g. "headroom").
    public var label: String? = nil
    public var isRunning: Bool { !running.isEmpty }
    /// Frontend URL first: the declared port when it's among the running ones.
    public var port: Int? { running.first?.port ?? declared?.port }

    public var name: String {
        if let label { return label }
        if let d = declared { return d.name }
        guard let p = running.first else { return "Server" }
        if let f = p.framework { return f.replacingOccurrences(of: "Node.js · ", with: "") }
        return p.command
    }
}

/// A project, an app, a macOS component, or a lone process, with its ports.
public struct PortGroup: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case project, app, system, other }

    public let kind: Kind
    /// Project root, app bundle path, macOS display name, or pid.
    public let key: String
    public let title: String
    /// `~/Documents/api` for a project, the macOS note for AirPlay, nil otherwise.
    public let subtitle: String?
    public let branch: String?
    /// Homebrew formula when an `.other` process is one of the user's brew services.
    public let brewService: String?
    /// Projects only: declared + running servers, frontend first.
    public var servers: [ServerSlot] = []
    /// Projects only: the script that starts everything (`pnpm dev` → run.sh).
    public var launcher: DeclaredServer?
    /// Sorted by port.
    public let ports: [PortInfo]

    public var id: String { "\(kind.rawValue):\(key)" }
    public var pids: [Int32] { Array(Set(ports.map(\.pid))).sorted() }
}

/// The Ports tab's view model: four sections, filtered by the search box.
public struct PortSections: Equatable, Sendable {
    public var projects: [PortGroup] = []
    public var apps: [PortGroup] = []
    public var system: [PortGroup] = []
    public var other: [PortGroup] = []
    /// Ports shown after filtering.
    public var portCount = 0

    public var isEmpty: Bool { portCount == 0 }

    /// `brewServices`: pid → formula for the user's running Homebrew services;
    /// a process (or its parent) on that list is labeled as that service.
    public static func build(_ snapshot: PortsSnapshot, brewServices: [Int32: String] = [:],
                             query: String = "", home: String = Paths.home.path) -> PortSections {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var buckets: [String: (kind: PortGroup.Kind, key: String, ports: [PortInfo])] = [:]
        for p in snapshot.ports {
            let (kind, key) = groupKey(p)
            buckets["\(kind.rawValue):\(key)", default: (kind, key, [])].ports.append(p)
        }
        // `3000` shows only what's on 3000; prefixes (`30`) apply when nothing matches exactly.
        let exactNumber = !q.isEmpty && q.allSatisfy(\.isNumber)
            && snapshot.ports.contains { String($0.port) == q || String($0.pid) == q }
        var out = PortSections()
        for (_, b) in buckets {
            let group = makeGroup(b.kind, key: b.key, ports: b.ports, snapshot: snapshot, brew: brewServices, home: home)
            let shown = q.isEmpty ? group.ports : group.ports.filter { matches($0, group: group, query: q, exact: exactNumber) }
            guard !shown.isEmpty else { continue }
            var g = PortGroup(kind: group.kind, key: group.key, title: group.title, subtitle: group.subtitle,
                              branch: group.branch, brewService: group.brewService, ports: shown)
            if g.kind == .project {
                // While searching, a card shows only the servers that matched.
                let declared = snapshot.declared[g.key] ?? []
                let all = slots(declared: declared.filter { !$0.isLauncher }, running: shown)
                g.servers = q.isEmpty ? all : all.filter(\.isRunning)
                g.launcher = declared.first { $0.isLauncher && $0.dir == g.key } ?? declared.first(where: \.isLauncher)
            }
            out.portCount += shown.count
            switch g.kind {
            case .project: out.projects.append(g)
            case .app: out.apps.append(g)
            case .system: out.system.append(g)
            case .other: out.other.append(g)
            }
        }
        let byTitle: (PortGroup, PortGroup) -> Bool = {
            ($0.title.localizedLowercase, $0.key) < ($1.title.localizedLowercase, $1.key)
        }
        out.projects.sort(by: byTitle)
        out.apps.sort(by: byTitle)
        out.system.sort(by: byTitle)
        out.other.sort { ($0.ports.first?.port ?? 0, $0.key) < ($1.ports.first?.port ?? 0, $1.key) }
        return out
    }

    /// Pairs running ports with declared servers (by script file, then port).
    /// Unclaimed ports become their own slots, one per process.
    static func slots(declared: [DeclaredServer], running: [PortInfo]) -> [ServerSlot] {
        var unclaimed = running
        var out: [ServerSlot] = declared.map { d in
            let mine = unclaimed.filter { ProjectServers.matches($0, d) }
            let pids = Set(mine.map(\.pid))
            // Every port of a matched process belongs to the same server.
            let all = unclaimed.filter { pids.contains($0.pid) }
            unclaimed.removeAll { pids.contains($0.pid) }
            return ServerSlot(declared: d, running: all.sorted { $0.port < $1.port }, role: d.role)
        }
        for (_, ports) in Dictionary(grouping: unclaimed, by: \.pid) {
            let p = ports.sorted { $0.port < $1.port }
            if let tool = toolName(p[0]) {
                out.append(ServerSlot(declared: nil, running: p, role: .tool, label: tool))
            } else {
                out.append(ServerSlot(declared: nil, running: p, role: inferRole(p[0])))
            }
        }
        return out.sorted { ($0.role, $0.port ?? .max, $0.id) < ($1.role, $1.port ?? .max, $1.id) }
    }

    /// Globally installed tools (uv/pipx/cargo/global npm) that merely run
    /// from inside a project folder — named after the tool, not the runtime.
    static let toolDirs = ["/.local/share/uv/tools/", "/.local/pipx/", "/.cargo/bin/", "/.bun/install/global/",
                           "/lib/node_modules/", "/.npm/_npx/", "/.local/bin/"]

    static func toolName(_ p: PortInfo) -> String? {
        let paths = [p.executablePath, p.commandLine?.split(separator: " ").first.map(String.init)].compactMap { $0 }
        guard let path = paths.first(where: { pp in toolDirs.contains { pp.contains($0) } }) else { return nil }
        let argv = (p.commandLine ?? "").split(separator: " ").map(String.init)
        if let i = argv.firstIndex(of: "-m"), i + 1 < argv.count {
            return String(argv[i + 1].split(separator: ".").first ?? "")
        }
        // …/uv/tools/<tool>/bin/python → <tool>
        for marker in ["/uv/tools/", "/pipx/venvs/", "/lib/node_modules/"] {
            if let r = path.range(of: marker) {
                return path[r.upperBound...].split(separator: "/").first.map(String.init)
            }
        }
        return (path as NSString).lastPathComponent
    }

    static func inferRole(_ p: PortInfo) -> ServerRole {
        if let f = p.framework, ProjectServers.frontendFrameworks.contains(f) { return .frontend }
        if [5432, 3306, 6379, 27017, 1433, 9200, 11211].contains(p.port) { return .database }
        return .backend
    }

    static func groupKey(_ p: PortInfo) -> (PortGroup.Kind, String) {
        switch p.owner {
        case let .project(root): (.project, root)
        case let .app(bundle): (.app, bundle)
        // ControlCenter's two rows (5000 + 7000) are one "AirPlay Receiver".
        case .system: (.system, PortClassifier.systemName(command: p.command).title)
        case .other: (.other, String(p.pid))
        }
    }

    static func makeGroup(_ kind: PortGroup.Kind, key: String, ports: [PortInfo], snapshot: PortsSnapshot,
                          brew: [Int32: String], home: String) -> PortGroup {
        let sorted = ports.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
        let first = sorted[0]
        switch kind {
        case .project:
            return PortGroup(kind: kind, key: key, title: JunkGrouping.displayName(key),
                             subtitle: abbreviate(key, home: home), branch: snapshot.branches[key],
                             brewService: nil, ports: sorted)
        case .app:
            return PortGroup(kind: kind, key: key, title: PortClassifier.appName(bundlePath: key), subtitle: nil,
                             branch: nil, brewService: nil, ports: sorted)
        case .system:
            let name = PortClassifier.systemName(command: first.command)
            return PortGroup(kind: kind, key: key, title: name.title, subtitle: name.note, branch: nil,
                             brewService: nil, ports: sorted)
        case .other:
            let formula = brew[first.pid] ?? first.ppid.flatMap { brew[$0] }
            return PortGroup(kind: kind, key: key, title: first.command, subtitle: nil, branch: nil,
                             brewService: formula, ports: sorted)
        }
    }

    /// A number matches a port or pid exactly (`exact`), else a port by prefix
    /// (typing `30` → 3000, 3001); text matches process, framework, well-known
    /// label, or the project / app / service name.
    static func matches(_ p: PortInfo, group: PortGroup, query q: String, exact: Bool) -> Bool {
        if q.allSatisfy(\.isNumber) {
            return String(p.port) == q || String(p.pid) == q || (!exact && String(p.port).hasPrefix(q))
        }
        let fields = [p.command, p.framework, PortFramework.wellKnownLabel(port: p.port), group.title, group.brewService]
        return fields.contains { $0?.lowercased().contains(q) == true }
    }

    /// `/Users/me/Documents/api` → `~/Documents/api`.
    public static func abbreviate(_ path: String, home: String = Paths.home.path) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
