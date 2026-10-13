import Foundation
import Testing
@testable import KavachCore

/// Discovery against a temp "home" — never the real one.
@Suite struct ProjectsDiscoveryTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("projects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    /// A git repository at `rel` (a `.git` folder with a HEAD).
    @discardableResult
    func repo(_ rel: String, branch: String = "main") throws -> URL {
        let dir = home.appendingPathComponent(rel, isDirectory: true)
        let git = dir.appendingPathComponent(".git", isDirectory: true)
        try fm.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("ref: refs/heads/\(branch)\n".utf8).write(to: git.appendingPathComponent("HEAD"))
        return dir
    }

    func path(_ rel: String) -> String { home.appendingPathComponent(rel).standardizedFileURL.path }

    func discover(extra: [String] = []) async -> [String] {
        await ProjectDiscovery.discover(home: home, extraRoots: extra).map(\.root)
    }

    @Test func findsGitRepositories() async throws {
        try repo("code/shop")
        try repo("Documents/site", branch: "dev")
        let found = await ProjectDiscovery.discover(home: home)
        #expect(found.map(\.root) == [path("Documents/site"), path("code/shop")])
        #expect(found.first?.branch == "dev")
        #expect(found.first?.name == "site")
    }

    @Test func subAppReposLiftToTheirProjectAndDedupe() async throws {
        try repo("work/rl_zoho/frontend")
        try repo("work/rl_zoho/backend")
        try repo("work/rl_zoho")
        #expect(await discover() == [path("work/rl_zoho")])
    }

    @Test func prunesDependencyHiddenAndLibraryFolders() async throws {
        try repo("app")
        try repo("app/node_modules/left-pad")
        try repo("other/node_modules/pkg")
        try repo(".config/nvim")
        try repo("code/.hidden/thing")
        try repo("Library/Caches/x")
        #expect(await discover() == [path("app")])
    }

    @Test func ignoresHomeContainersGitFilesAndDeepRepos() async throws {
        try repo("Documents")             // a container folder that's a repo
        try repo("")                      // home itself (dotfiles)
        try repo("a/b/c/d/e/f")           // .git at depth 7
        try repo("a/b/c/d/e")             // .git at depth 6 — found
        let sub = home.appendingPathComponent("lib/vendored", isDirectory: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("gitdir: ../../.git/modules/vendored\n".utf8).write(to: sub.appendingPathComponent(".git"))
        #expect(await discover() == [path("a/b/c/d/e")])
    }

    @Test func includesPortOwnersThatExist() async throws {
        try repo("code/shop")
        let plain = home.appendingPathComponent("scratch/server", isDirectory: true)
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        let found = await discover(extra: [plain.path, path("code/shop"), path("gone")])
        #expect(found == [path("code/shop"), plain.path])
    }

    @Test func readsActivityAndDeclaredServers() throws {
        let dir = try repo("web")
        let pkg = dir.appendingPathComponent("package.json")
        try Data(#"{"scripts":{"dev":"next dev"}}"#.utf8).write(to: pkg)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for entry in try fm.contentsOfDirectory(atPath: dir.path) {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: dir.appendingPathComponent(entry).path)
        }
        let info = ProjectDiscovery.info(root: dir.path)
        #expect(info.lastActivityEpoch == 1_700_000_000)
        #expect(info.lastActivity == date)
        #expect(info.declared.map(\.framework) == ["Next.js"])
        #expect(info.branch == "main")
    }

    @Test func findArgsPruneBeforePrinting() {
        let args = ProjectDiscovery.findArgs(home: "/Users/me")
        #expect(args.prefix(3) == ["/Users/me", "-maxdepth", "6"])
        let git = args.firstIndex(of: ".git")!, hidden = args.firstIndex(of: ".*")!
        #expect(git < hidden)
        #expect(args.contains("node_modules"))
        #expect(args.contains("/Users/me/Library"))
    }
}

@Suite struct ProjectsListTests {
    let home = "/Users/me"

    func project(_ name: String, age: UInt64, declared: [DeclaredServer] = []) -> ProjectInfo {
        ProjectInfo(root: "\(home)/code/\(name)", lastActivityEpoch: 1_000_000 - age, branch: nil, declared: declared)
    }

    var projects: [ProjectInfo] {
        [project("beta", age: 10), project("alpha", age: 500), project("gamma", age: 1), project("Delta", age: 50)]
    }

    func arrange(query: String = "", filter: ProjectFilter = .all, sort: ProjectSort = .recent,
                 facts: ProjectFacts = ProjectFacts()) -> [String] {
        ProjectList.arrange(projects, query: query, filter: filter, sort: sort, facts: facts, home: home).map(\.name)
    }

    @Test func sortsByRecentActivityThenName() {
        #expect(arrange() == ["gamma", "beta", "Delta", "alpha"])
        #expect(arrange(sort: .name) == ["alpha", "beta", "Delta", "gamma"])
    }

    @Test func sortsByRemovableSize() {
        let facts = ProjectFacts(removable: ["\(home)/code/alpha": 900, "\(home)/code/Delta": 50])
        #expect(arrange(sort: .removable, facts: facts) == ["alpha", "Delta", "gamma", "beta"])
    }

    @Test func pinnedAlwaysComeFirst() {
        let facts = ProjectFacts(pinned: ["\(home)/code/alpha", "\(home)/code/Delta"])
        #expect(arrange(facts: facts) == ["Delta", "alpha", "gamma", "beta"])
        #expect(arrange(sort: .name, facts: facts) == ["alpha", "Delta", "beta", "gamma"])
        #expect(arrange(filter: .pinned, facts: facts) == ["Delta", "alpha"])
    }

    @Test func filtersRunningAndUnsaved() {
        let facts = ProjectFacts(running: ["\(home)/code/beta"], unsaved: ["\(home)/code/alpha", "\(home)/code/gamma"])
        #expect(arrange(filter: .running, facts: facts) == ["beta"])
        #expect(arrange(filter: .unsaved, facts: facts) == ["gamma", "alpha"])
    }

    @Test func searchesNameAndPath() {
        #expect(arrange(query: "ALP") == ["alpha"])
        #expect(arrange(query: "~/code/del") == ["Delta"])
        #expect(arrange(query: "/Users/me/code/g") == ["gamma"])
        #expect(arrange(query: "  ") == arrange())
        #expect(arrange(query: "nope").isEmpty)
    }

    @Test func groupMatchesDeclaredServersToLivePorts() {
        let root = "\(home)/code/web"
        let next = DeclaredServer(dir: root, script: "dev", command: "next dev", framework: "Next.js", role: .frontend,
                                  port: 3000, runner: "pnpm", entry: nil)
        let api = DeclaredServer(dir: root + "/api", script: "dev", command: "node index.js", framework: nil,
                                 role: .backend, port: 4000, runner: "pnpm", entry: "index.js")
        var launcher = DeclaredServer(dir: root, script: "dev:all", command: "./run.sh", framework: nil, role: .backend,
                                      port: nil, runner: "pnpm", entry: nil)
        launcher.isLauncher = true
        let p = ProjectInfo(root: root, lastActivityEpoch: 1, branch: "main", declared: [next, api, launcher])
        let ports = [
            PortInfo(pid: 10, command: "node", user: "me", port: 3000, proto: "IPv4", owner: .project(root: root)),
            PortInfo(pid: 11, command: "node", user: "me", port: 3000, proto: "IPv4", owner: .project(root: "/elsewhere")),
        ]
        let g = ProjectList.group(for: p, ports: ports, branch: "feature", home: home)
        #expect(g.kind == .project && g.key == root && g.title == "web" && g.subtitle == "~/code/web")
        #expect(g.branch == "feature")
        #expect(g.ports.map(\.pid) == [10])
        #expect(g.servers.map(\.name) == ["Next.js", "index.js"])
        #expect(g.servers.map(\.isRunning) == [true, false])
        #expect(g.launcher == launcher)
        #expect(Set(ProjectList.portsByRoot(ports).keys) == ["/elsewhere", root])
    }
}
