import Foundation

/// A repository or workspace with every removable folder inside it —
/// `rideorbit` holding `web/node_modules`, `server/node_modules`, `mobile/Pods`.
public struct JunkGroup: Identifiable, Equatable, Sendable {
    public var id: String { root }
    public let root: String
    public var name: String { JunkGrouping.displayName(root) }
    public let items: [JunkItem]

    public var bytes: UInt64 { items.compactMap(\.bytes).reduce(0, +) }
    public var isMeasured: Bool { items.allSatisfy { $0.bytes != nil } }
    public var lastUsedEpoch: UInt64 { items.map(\.lastUsedEpoch).max() ?? 0 }
    public var deletable: [JunkItem] { items.filter { !$0.locked } }
    public var lockedCount: Int { items.filter(\.locked).count }

    /// The group's freshest status: one active sub-project makes the repo active.
    public var category: JunkItem.Category {
        if items.contains(where: { $0.category == .active }) { return .active }
        if items.contains(where: { $0.category == .stale }) { return .stale }
        return .dead
    }

    /// `web/node_modules` for `<root>/web/node_modules`.
    public func relativePath(of item: JunkItem) -> String {
        item.path.hasPrefix(root + "/") ? String(item.path.dropFirst(root.count + 1)) : item.path
    }
}

public enum JunkGrouping {
    /// Folders that hold many projects — never a group of their own, even if
    /// someone made them a git repo.
    static let containerNames: Set<String> = ["Documents", "Desktop", "Downloads"]

    /// Sub-app folder names that are never a project on their own:
    /// `rl_zoho/frontend` belongs to `rl_zoho`, git or not.
    static let subAppNames: Set<String> = [
        "frontend", "front-end", "backend", "back-end", "web", "webapp", "server", "client", "app", "api",
        "mobile", "admin", "ui", "site", "www", "docs", "dashboard", "landing", "extension", "functions",
        "infra", "apps", "packages", "services", "ios", "android",
    ]

    /// Nearest ancestor of `project` (itself included, home excluded) that is a
    /// git repository root or a JS workspace root. Without one, a sub-app
    /// folder (`frontend`, `server`, …) groups under its parent; anything else
    /// is its own project.
    public static func root(forProject project: URL, home: URL) -> URL {
        let fm = FileManager.default
        let homePath = home.standardizedFileURL.path
        var dir = project.standardizedFileURL
        var workspace: URL?
        var found: URL?
        while dir.path.hasPrefix(homePath + "/") {
            if !isContainer(dir, homePath: homePath) {
                if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { found = dir; break }
                if workspace == nil, isWorkspaceRoot(dir) { workspace = dir }
            }
            dir = dir.deletingLastPathComponent()
        }
        return liftSubApp(found ?? workspace ?? project.standardizedFileURL, homePath: homePath)
    }

    /// A root named like a sub-app (`frontend`, even when it is its own git
    /// repo) belongs to its parent project — unless the parent is home or a
    /// container folder.
    static func liftSubApp(_ root: URL, homePath: String) -> URL {
        var r = root
        while subAppNames.contains(r.lastPathComponent.lowercased()) {
            let parent = r.deletingLastPathComponent()
            guard parent.path.hasPrefix(homePath + "/"), !isContainer(parent, homePath: homePath),
                  !holderNames.contains(parent.lastPathComponent.lowercased()),
                  isProjectFolder(parent, besides: r) else { break }
            r = parent
        }
        return r
    }

    /// A project's display name. A root that is still a sub-app folder (a lone
    /// `frontend` that couldn't join a parent) is shown as `parent/frontend`,
    /// so a list never has rows called just "frontend".
    public static func displayName(_ root: String) -> String {
        let name = (root as NSString).lastPathComponent
        guard subAppNames.contains(name.lowercased()) else { return name }
        let parentPath = (root as NSString).deletingLastPathComponent
        let parent = (parentPath as NSString).lastPathComponent
        // In a holder (`~/code/api`), a container (`~/Documents/web`) or home, the name alone is clearer.
        let plain = parent.isEmpty || parentPath == Paths.home.path
            || holderNames.contains(parent.lowercased()) || containerNames.contains(parent)
        return plain ? name : "\(parent)/\(name)"
    }

    /// Folders that just hold unrelated repos (`~/code/api` is its own project).
    static let holderNames: Set<String> = [
        "code", "projects", "project", "repos", "repositories", "src", "source", "dev", "development", "work",
        "workspace", "workspaces", "github", "gitlab", "git", "sites", "clients", "sandbox", "playground", "personal",
    ]

    /// The parent is a project itself: it has its own files (README, compose,
    /// `api.py`…) or another sibling sub-project — `cms-school/{be-strapi,frontend}`.
    static func isProjectFolder(_ dir: URL, besides child: URL) -> Bool {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let manifests = ["package.json", ".git", "manage.py", "pyproject.toml", "Cargo.toml", "go.mod", "pom.xml",
                         "build.gradle", "Gemfile", "composer.json"]
        for e in entries where e.lastPathComponent != child.lastPathComponent && e.lastPathComponent != ".DS_Store" {
            let isDir = (try? e.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir, !e.lastPathComponent.hasPrefix(".") { return true }
            if e.lastPathComponent == ".git" { return true }
            if isDir, manifests.contains(where: { fm.fileExists(atPath: e.appendingPathComponent($0).path) }) { return true }
            // The classic pair: `frontend/` next to `backend/` (or `api/`, `server/`…).
            if isDir, subAppNames.contains(e.lastPathComponent.lowercased()) { return true }
        }
        return false
    }

    static func isContainer(_ dir: URL, homePath: String) -> Bool {
        dir.path == homePath
            || (dir.deletingLastPathComponent().path == homePath && containerNames.contains(dir.lastPathComponent))
    }

    static func isWorkspaceRoot(_ dir: URL) -> Bool {
        let fm = FileManager.default
        if ["pnpm-workspace.yaml", "lerna.json", "nx.json", "turbo.json"].contains(where: {
            fm.fileExists(atPath: dir.appendingPathComponent($0).path)
        }) { return true }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("package.json")),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return obj["workspaces"] != nil
    }

    /// Items grouped by `groupRoot`, biggest group first.
    public static func group(_ items: [JunkItem]) -> [JunkGroup] {
        Dictionary(grouping: items, by: \.groupRoot)
            .map { JunkGroup(root: $0.key, items: $0.value.sorted { ($0.bytes ?? 0, $1.path) > ($1.bytes ?? 0, $0.path) }) }
            .sorted { ($0.bytes, $1.root) > ($1.bytes, $0.root) }
    }
}
