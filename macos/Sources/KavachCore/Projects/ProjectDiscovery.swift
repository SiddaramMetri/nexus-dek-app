import Foundation

/// A coding project on this Mac: a git repository lifted to its project root
/// (`rl_zoho/frontend` with its own `.git` is `rl_zoho`), or a folder that owns
/// a listening port right now.
public struct ProjectInfo: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { root }
    public let root: String
    public var name: String { JunkGrouping.displayName(root) }
    /// Newest top-level mtime, seconds since 1970; 0 when unknown.
    public let lastActivityEpoch: UInt64
    /// From `.git/HEAD` at discovery time.
    public let branch: String?
    /// Dev servers and launchers the project declares.
    public let declared: [DeclaredServer]

    public init(root: String, lastActivityEpoch: UInt64, branch: String?, declared: [DeclaredServer]) {
        self.root = root
        self.lastActivityEpoch = lastActivityEpoch
        self.branch = branch
        self.declared = declared
    }

    public var lastActivity: Date? {
        lastActivityEpoch > 0 ? Date(timeIntervalSince1970: TimeInterval(lastActivityEpoch)) : nil
    }
}

/// Finds projects under $HOME. Read-only: one `find`, then file reads per
/// project (top-level mtimes, `.git/HEAD`, package.json scripts). No git
/// subprocesses — status is loaded lazily per card.
public enum ProjectDiscovery {
    static let maxDepth = 6

    /// Project folders found last time — read at launch so the list appears
    /// instantly, before the (slower) home-folder walk refreshes it.
    static let index = JSONStore<[String]>(file: "index.json", key: "projectRoots")

    public static func cachedRoots() -> [String] {
        (index.load() ?? []).filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Facts for known roots, no `find` — the fast path at launch.
    public static func infos(roots: [String]) async -> [ProjectInfo] {
        await withTaskGroup(of: ProjectInfo.self) { group in
            for root in roots { group.addTask { info(root: root) } }
            var out: [ProjectInfo] = []
            for await i in group { out.append(i) }
            return out.sorted { $0.root < $1.root }
        }
    }

    /// `find` over $HOME: prunes Library / Trash / media folders (Music,
    /// Pictures and Movies each pop a privacy prompt), prints and prunes every
    /// `.git` directory, prunes node_modules and other hidden folders.
    static func findArgs(home h: String) -> [String] {
        [h, "-maxdepth", String(maxDepth),
         "(", "-path", "\(h)/Library", "-o", "-path", "\(h)/.Trash", "-o", "-path", "\(h)/Music",
         "-o", "-path", "\(h)/Pictures", "-o", "-path", "\(h)/Movies", ")", "-prune",
         "-o", "-name", ".git", "-type", "d", "-prune", "-print",
         "-o", "-name", "node_modules", "-prune",
         "-o", "-name", ".*", "-prune"]
    }

    /// `.git` folders → deduped project roots, in input order. Never home or a
    /// container folder (Documents, Desktop, Downloads), even when it's a repo.
    static func roots(gitDirs: [URL], home: URL) -> [String] {
        let homePath = home.standardizedFileURL.path
        var seen = Set<String>()
        var out: [String] = []
        for dir in gitDirs {
            let root = JunkGrouping.root(forProject: dir.deletingLastPathComponent(), home: home).standardizedFileURL
            guard root.path.hasPrefix(homePath + "/"), !JunkGrouping.isContainer(root, homePath: homePath) else { continue }
            if seen.insert(root.path).inserted { out.append(root.path) }
        }
        return out
    }

    /// Every git project under `home`, plus `extraRoots` (projects owning
    /// ports that aren't repositories). Sorted by path.
    public static func discover(home: URL = Paths.home, extraRoots: [String] = []) async -> [ProjectInfo] {
        let out = await Proc.anyOutput("find", findArgs(home: home.path))
        let gitDirs = out.split(whereSeparator: \.isNewline).map { URL(fileURLWithPath: String($0), isDirectory: true) }
        var all = roots(gitDirs: gitDirs, home: home)
        var seen = Set(all)
        for r in extraRoots where FileManager.default.fileExists(atPath: r) && seen.insert(r).inserted { all.append(r) }
        index.save(all)
        return await infos(roots: all)
    }

    /// One project's facts from its files (no subprocesses).
    public static func info(root: String) -> ProjectInfo {
        ProjectInfo(root: root,
                    lastActivityEpoch: DevCleaner.lastUsedEpoch(URL(fileURLWithPath: root, isDirectory: true)),
                    branch: GitHead.branch(atRoot: root),
                    declared: ProjectServers.discover(root: root))
    }
}
