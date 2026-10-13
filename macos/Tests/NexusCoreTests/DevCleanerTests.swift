import Foundation
import Testing
@testable import NexusCore

/// Temp-directory round trips — never touches the real home or Trash.
@Suite struct DevCleanerTests {
    let home: URL
    let now = UInt64(Date().timeIntervalSince1970)
    let fm = FileManager.default

    init() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("devclean-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    /// A project folder whose own files are `ageDays` old, plus `files` (name → content).
    @discardableResult
    func project(_ rel: String, ageDays: UInt64, files: [String: String] = ["package.json": "{}"]) throws -> URL {
        let p = home.appendingPathComponent(rel, isDirectory: true)
        try fm.createDirectory(at: p, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: TimeInterval(now - ageDays * 86_400))
        for (name, content) in files {
            let f = p.appendingPathComponent(name)
            try Data(content.utf8).write(to: f)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: f.path)
        }
        return p
    }

    /// A junk folder with a little content inside.
    @discardableResult
    func junk(_ project: URL, _ name: String, extra: String? = nil) throws -> URL {
        let d = project.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: d.appendingPathComponent("x"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: d.appendingPathComponent("x/f"))
        if let extra { try Data().write(to: d.appendingPathComponent(extra)) }
        return d
    }

    func item(_ dir: URL) -> JunkItem? { DevCleaner.item(for: dir, now: now, home: home) }

    // MARK: Matching — only provable junk

    @Test func everyKindNeedsItsMarker() throws {
        let js = try project("js", ageDays: 400, files: ["package.json": "{}", ".gitignore": "/dist\nbuild/\n"])
        #expect(item(try junk(js, "node_modules"))?.kind == .nodeModules)
        #expect(item(try junk(js, ".next"))?.kind == .jsFrameworkCache)
        #expect(item(try junk(js, "dist"))?.kind == .jsBuildOutput)
        #expect(item(try junk(js, "build"))?.kind == .jsBuildOutput)

        let rust = try project("rust", ageDays: 400, files: ["Cargo.toml": ""])
        #expect(item(try junk(rust, "target"))?.kind == .rustTarget)
        let py = try project("py", ageDays: 400, files: ["main.py": ""])
        #expect(item(try junk(py, ".venv", extra: "pyvenv.cfg"))?.kind == .pythonVenv)
        let ios = try project("ios", ageDays: 400, files: ["Podfile": ""])
        #expect(item(try junk(ios, "Pods"))?.kind == .cocoaPods)
        let android = try project("android", ageDays: 400, files: ["build.gradle": ""])
        #expect(item(try junk(android, ".gradle"))?.kind == .gradleCache)
    }

    @Test func ordinaryFoldersWithJunkNamesAreNeverOffered() throws {
        // `build` / `dist` without a gitignore entry, in a JS project.
        let js = try project("js", ageDays: 400)
        #expect(item(try junk(js, "build")) == nil)
        #expect(item(try junk(js, "dist")) == nil)
        // `target` without Cargo.toml (e.g. a Maven or design project).
        let other = try project("other", ageDays: 400, files: ["pom.xml": ""])
        #expect(item(try junk(other, "target")) == nil)
        // `venv` that isn't a virtualenv, `Pods` without a Podfile, `.next` outside a JS project.
        #expect(item(try junk(other, "venv")) == nil)
        #expect(item(try junk(other, "Pods")) == nil)
        #expect(item(try junk(other, ".next")) == nil)
        // A gitignore that only *negates* or comments the name doesn't count.
        let neg = try project("neg", ageDays: 400, files: ["package.json": "{}", ".gitignore": "# dist\n!build\n"])
        #expect(item(try junk(neg, "dist")) == nil)
        #expect(item(try junk(neg, "build")) == nil)
    }

    // MARK: Age and locking

    @Test func classifiesAndLocksByProjectAge() throws {
        #expect(item(try junk(try project("fresh", ageDays: 2), "node_modules"))?.locked == true)
        let active = item(try junk(try project("active", ageDays: 20), "node_modules"))
        #expect(active?.category == .active && active?.locked == false)
        #expect(item(try junk(try project("stale", ageDays: 90), "node_modules"))?.category == .stale)
        #expect(item(try junk(try project("dead", ageDays: 400), "node_modules"))?.category == .dead)
        let dl = item(try junk(try project("Downloads/demo", ageDays: 1), "node_modules"))
        #expect(dl?.category == .dead && dl?.locked == true)
    }

    @Test func junkFoldersDontCountAsProjectActivity() throws {
        let p = try project("built", ageDays: 400, files: ["package.json": "{}", ".gitignore": "dist"])
        try junk(p, "dist")  // written "now" by a build
        let nm = try junk(p, "node_modules")
        #expect(item(nm)?.category == .dead)
    }

    // MARK: Delete

    @Test func trashesOnlyValidatedFolders() async throws {
        let dead = try junk(try project("code/dead", ageDays: 400), "node_modules")
        let locked = try junk(try project("code/fresh", ageDays: 1), "node_modules")
        let plainBuild = try junk(try project("code/plain", ageDays: 400), "build")
        let outside = fm.temporaryDirectory.appendingPathComponent("elsewhere/node_modules").path
        let missing = home.appendingPathComponent("gone/node_modules").path

        var removed: [String] = []
        let result = await DevCleaner.trash([dead.path, locked.path, plainBuild.path, outside, missing],
                                            home: home, now: now) { url in
            removed.append(url.path)
            try FileManager.default.removeItem(at: url)
        }
        #expect(result.removed == [dead.path])
        #expect(result.freedBytes > 0)
        #expect(result.skipped.count == 4)
        #expect(removed == [dead.standardizedFileURL.path])
        #expect(fm.fileExists(atPath: locked.path))
        #expect(fm.fileExists(atPath: plainBuild.path))
        // The project itself is untouched.
        #expect(fm.fileExists(atPath: dead.deletingLastPathComponent().appendingPathComponent("package.json").path))

        let check = DevCleaner.verifyGone([dead.path, locked.path])
        #expect(check.gone == [dead.path])
        #expect(check.stillThere == [locked.path])
    }

    @Test func refusesSymlinksLibraryAndHomeItself() throws {
        let real = try junk(try project("real", ageDays: 400), "node_modules")
        let linkedProject = try project("linked", ageDays: 400)
        let link = linkedProject.appendingPathComponent("node_modules")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(DevCleaner.validated(link.path, home: home, now: now) == nil)

        let lib = try junk(try project("Library/Caches/x", ageDays: 400), "node_modules")
        #expect(DevCleaner.validated(lib.path, home: home, now: now) == nil)
        #expect(DevCleaner.validated(home.path, home: home, now: now) == nil)
    }

    @Test func declinedConfirmChangesNothing() async throws {
        let dead = try junk(try project("dead", ageDays: 400), "node_modules")
        let it = try #require(item(dead))
        await #expect(throws: AppError.userCancelled) {
            _ = try await DevCleaner.moveToTrash([it], confirmer: Decline())
        }
        #expect(fm.fileExists(atPath: dead.path))
    }

    @Test func confirmSaysWhatStaysAndHowItComesBack() {
        let items = (0..<10).map {
            JunkItem(path: "/u/p\($0)/node_modules", kind: $0 == 0 ? .rustTarget : .nodeModules,
                     groupRoot: "/u/p\($0)", lastUsedEpoch: 0, category: .dead, locked: false, bytes: 1_048_576)
        }
        let msg = DevCleaner.confirmMessage(items, bytes: 10 * 1_048_576)
        #expect(msg.hasPrefix("10 MB from: p0/node_modules, p1/node_modules"))
        #expect(msg.contains("+2 more"))
        #expect(msg.contains("source code, package.json and lockfiles stay"))
        #expect(msg.contains("npm / pnpm / yarn install · cargo build"))
    }

    // MARK: Grouping by repository

    @Test func monorepoSubProjectsShareOneGroup() throws {
        let repo = try project("Documents/rideorbit", ageDays: 400, files: ["README.md": ""])
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let web = try junk(try project("Documents/rideorbit/web", ageDays: 400), "node_modules")
        let server = try junk(try project("Documents/rideorbit/server", ageDays: 400), "node_modules")
        let ios = try junk(try project("Documents/rideorbit/mobile/ios", ageDays: 400, files: ["Podfile": ""]), "Pods")

        let items = [web, server, ios].compactMap(item)
        #expect(items.count == 3)
        #expect(Set(items.map(\.groupRoot)) == [repo.standardizedFileURL.path])
        let groups = JunkGrouping.group(items)
        #expect(groups.count == 1)
        #expect(groups[0].name == "rideorbit")
        #expect(Set(items.map { groups[0].relativePath(of: $0) }) == ["web/node_modules", "server/node_modules", "mobile/ios/Pods"])
    }

    @Test func separateReposStaySeparateAndContainersNeverGroup() throws {
        // ~/Documents is a git repo here, but it's a container — projects inside stay apart.
        let docs = home.appendingPathComponent("Documents", isDirectory: true)
        try fm.createDirectory(at: docs.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let a = try junk(try project("Documents/scaler-rl/rl_jira", ageDays: 400), "node_modules")
        let b = try junk(try project("Documents/scaler-rl/rl_redfin", ageDays: 400), "node_modules")
        let groups = JunkGrouping.group([a, b].compactMap(item))
        #expect(groups.map(\.name).sorted() == ["rl_jira", "rl_redfin"])
    }

    @Test func workspaceRootGroupsWithoutGit() throws {
        let mono = try project("code/mono", ageDays: 400, files: ["package.json": #"{"workspaces":["apps/*"]}"#])
        let app = try junk(try project("code/mono/apps/site", ageDays: 400), "node_modules")
        let rootNM = try junk(mono, "node_modules")
        let groups = JunkGrouping.group([app, rootNM].compactMap(item))
        #expect(groups.count == 1)
        #expect(groups[0].name == "mono")
        #expect(groups[0].items.count == 2)
    }

    @Test func subAppFoldersGroupUnderTheirProjectWithoutGit() throws {
        // No .git anywhere: frontend + backend still belong to rl_zoho.
        let fe = try junk(try project("Documents/scaler-rl/rl_zoho/frontend", ageDays: 400), "node_modules")
        let be = try junk(try project("Documents/scaler-rl/rl_zoho/backend", ageDays: 400), "node_modules")
        let other = try junk(try project("Documents/scaler-rl/rl_scc/frontend", ageDays: 400), "node_modules")
        let groups = JunkGrouping.group([fe, be, other].compactMap(item))
        // rl_zoho has frontend + backend → one project; rl_scc holds only a
        // frontend, so it stays its own folder but is named "rl_scc/frontend".
        #expect(groups.map(\.name).sorted() == ["rl_scc/frontend", "rl_zoho"])
        #expect(groups.first { $0.name == "rl_zoho" }?.items.count == 2)
        // A real project name stays its own project; a sub-app directly in a container stays too.
        let real = try junk(try project("Documents/excalidraw", ageDays: 400), "node_modules")
        let loose = try junk(try project("Desktop/frontend", ageDays: 400), "node_modules")
        #expect(item(real)?.groupRoot.hasSuffix("/Documents/excalidraw") == true)
        #expect(item(loose)?.groupRoot.hasSuffix("/Desktop/frontend") == true)
    }

    @Test func aSubAppThatIsItsOwnRepoStillGroupsUnderItsProject() throws {
        let fe = try project("Documents/cms-school/frontend", ageDays: 400)
        try fm.createDirectory(at: fe.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let nm = try junk(fe, "node_modules")
        let venv = try junk(try project("Documents/cms-school/backend", ageDays: 400, files: ["main.py": ""]), ".venv", extra: "pyvenv.cfg")
        let groups = JunkGrouping.group([nm, venv].compactMap(item))
        #expect(groups.map(\.name) == ["cms-school"])
        #expect(Set(groups[0].items.map { groups[0].relativePath(of: $0) }) == ["frontend/node_modules", "backend/.venv"])
    }

    @Test func groupStatusIsItsFreshestProject() {
        func it(_ p: String, _ c: JunkItem.Category, locked: Bool = false, bytes: UInt64) -> JunkItem {
            JunkItem(path: "/r/\(p)/node_modules", kind: .nodeModules, groupRoot: "/r", lastUsedEpoch: 0,
                     category: c, locked: locked, bytes: bytes)
        }
        let g = JunkGrouping.group([it("a", .dead, bytes: 5), it("b", .active, locked: true, bytes: 7)])[0]
        #expect(g.category == .active)
        #expect(g.bytes == 12)
        #expect(g.deletable.map(\.path) == ["/r/a/node_modules"])
        #expect(g.lockedCount == 1)
        #expect(g.items.first?.path == "/r/b/node_modules")  // biggest first
    }

    @Test func findArgsPrintAndPruneEveryKind() {
        let args = DevCleaner.findArgs(home: "/Users/me")
        for name in JunkKind.allFolderNames { #expect(args.contains(name)) }
        #expect(args.contains("/Users/me/Library"))
        #expect(args.suffix(4) == ["-o", "-name", ".*", "-prune"])
    }
}

private struct Decline: Confirmer {
    func confirm(title: String, message: String, action: String, destructive: Bool) async -> Bool { false }
}

@Suite struct GitSafetyTests {
    @Test func parsesBranchAheadAndChanges() {
        let s = GitSafety.parse("## main...origin/main [ahead 2, behind 1]\n M src/a.ts\n?? new.txt\nA  added.ts\n")
        #expect(s.branch == "main")
        #expect(s.ahead == 2)
        #expect(s.changed == 3)
        #expect(!s.noUpstream)
        #expect(s.summary == "3 uncommitted changes · 2 unpushed commits")
    }

    @Test func cleanAndNoUpstream() {
        let clean = GitSafety.parse("## main...origin/main\n")
        #expect(!clean.hasUnsavedWork && clean.summary == "clean")
        let local = GitSafety.parse("## feature/x\n")
        #expect(local.branch == "feature/x" && local.noUpstream)
        #expect(GitSafety.parse("## No commits yet on main\n").branch == "main")
    }

    @Test func warningNamesOnlyRiskyProjects() {
        let w = DevCleaner.gitWarning([
            "/u/a": GitSafety.Status(branch: "main", changed: 1, ahead: 0, noUpstream: false),
            "/u/b": GitSafety.Status(branch: "main", changed: 0, ahead: 0, noUpstream: false),
        ])
        #expect(w.contains("• a: 1 uncommitted change"))
        #expect(!w.contains("• b"))
        #expect(DevCleaner.gitWarning([:]) == "")
    }

    @Test func readsARealRepoWithoutTouchingIt() async throws {
        guard let git = GitSafety.gitPath else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitsafe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try await Proc.run(git, ["-C", dir.path, "init", "-q", "-b", "main"])
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
        let s = try #require(await GitSafety.status(dir.path))
        #expect(s.branch == "main")
        #expect(s.changed == 1)
        #expect(await GitSafety.status(FileManager.default.temporaryDirectory.path) == nil)
    }
}

@Suite struct DiskSpaceTests {
    @Test func readsTheStartupDisk() throws {
        let d = try #require(DiskSpace.current())
        #expect(d.total > 0 && d.free <= d.total)
    }

    @Test func warnsOnceUntilSpaceRecovers() {
        var armed = true
        #expect(DiskSpace.shouldWarn(free: 50_000_000_000, armed: &armed) == false)
        #expect(DiskSpace.shouldWarn(free: 8_000_000_000, armed: &armed) == true)
        #expect(DiskSpace.shouldWarn(free: 7_000_000_000, armed: &armed) == false)   // already told
        #expect(DiskSpace.shouldWarn(free: 11_000_000_000, armed: &armed) == false)  // not recovered enough
        #expect(DiskSpace.shouldWarn(free: 9_000_000_000, armed: &armed) == false)
        #expect(DiskSpace.shouldWarn(free: 13_000_000_000, armed: &armed) == false)  // re-arms
        #expect(DiskSpace.shouldWarn(free: 9_000_000_000, armed: &armed) == true)
    }
}

@Suite struct SubAppLiftTests {
    let fm = FileManager.default
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("lift-\(UUID().uuidString)", isDirectory: true)

    func dir(_ rel: String, files: [String] = []) throws -> URL {
        let d = home.appendingPathComponent(rel, isDirectory: true)
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        for f in files { try Data().write(to: d.appendingPathComponent(f)) }
        return d
    }

    func root(_ rel: String) -> String {
        JunkGrouping.root(forProject: home.appendingPathComponent(rel), home: home).lastPathComponent
    }

    @Test func standaloneApiRepoInAHolderStaysItself() throws {
        try dir("code/api/.git")
        try dir("code/web/.git")
        try dir("code/web", files: ["package.json"])
        #expect(root("code/api") == "api")
        #expect(root("code/web") == "web")
    }

    @Test func subAppsLiftWhenTheParentIsAProject() throws {
        try dir("Documents/cms-school/be-strapi", files: ["package.json"])
        try dir("Documents/cms-school/frontend/.git")
        try dir("Documents/cronpulse", files: ["docker-compose.yml"])
        try dir("Documents/cronpulse/frontend/.git")
        try dir("Documents/pdf-report-app", files: ["api.py"])
        try dir("Documents/pdf-report-app/frontend/.git")
        #expect(root("Documents/cms-school/frontend") == "cms-school")
        #expect(root("Documents/cronpulse/frontend") == "cronpulse")
        #expect(root("Documents/pdf-report-app/frontend") == "pdf-report-app")
    }

    @Test func loneSubAppInAnEmptyFolderStaysItself() throws {
        try dir("stuff/frontend/.git")
        #expect(root("stuff/frontend") == "frontend")
    }
}

@Suite struct CleanupSafetyTests {
    let fm = FileManager.default
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("safety-\(UUID().uuidString)", isDirectory: true)
    let now = UInt64(Date().timeIntervalSince1970)

    func make(_ rel: String, files: [String], junk: String, inside: String? = nil) throws -> URL {
        let p = home.appendingPathComponent(rel, isDirectory: true)
        try fm.createDirectory(at: p, withIntermediateDirectories: true)
        let old = Date(timeIntervalSince1970: TimeInterval(now - 400 * 86_400))
        for f in files {
            try Data("{}".utf8).write(to: p.appendingPathComponent(f))
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: p.appendingPathComponent(f).path)
        }
        let j = p.appendingPathComponent(junk, isDirectory: true)
        try fm.createDirectory(at: j, withIntermediateDirectories: true)
        if let inside { try Data().write(to: j.appendingPathComponent(inside)) }
        return j
    }

    @Test func venvWithoutRequirementsIsKept() throws {
        let bare = try make("py/bare", files: ["main.py"], junk: "venv", inside: "pyvenv.cfg")
        let item = try #require(DevCleaner.item(for: bare, now: now, home: home))
        #expect(item.locked && item.keepReason != nil)
        #expect(DevCleaner.validated(bare.path, home: home, now: now) == nil)

        let listed = try make("py/listed", files: ["main.py", "requirements.txt"], junk: ".venv", inside: "pyvenv.cfg")
        let ok = try #require(DevCleaner.item(for: listed, now: now, home: home))
        #expect(!ok.locked && ok.keepReason == nil)
        let split = try make("py/split", files: ["requirements-prod.txt"], junk: ".venv", inside: "pyvenv.cfg")
        #expect(DevCleaner.item(for: split, now: now, home: home)?.keepReason == nil)
    }

    @Test func nodeModulesWithoutLockfileWarnsButStaysDeletable() throws {
        let noLock = try make("js/nolock", files: ["package.json"], junk: "node_modules")
        let item = try #require(DevCleaner.item(for: noLock, now: now, home: home))
        #expect(item.warning != nil && !item.locked)
        let locked = try make("js/locked", files: ["package.json", "pnpm-lock.yaml"], junk: "node_modules")
        #expect(DevCleaner.item(for: locked, now: now, home: home)?.warning == nil)
    }

    @Test func workspaceLockfileAtTheRootCounts() throws {
        _ = try make("mono", files: ["package.json", "pnpm-lock.yaml", "pnpm-workspace.yaml"], junk: "node_modules")
        let app = try make("mono/apps/web", files: ["package.json"], junk: "node_modules")
        #expect(DevCleaner.item(for: app, now: now, home: home)?.warning == nil)
    }

    @Test func everyKindHasARebuildCost() {
        for k in JunkKind.allCases { #expect(!k.rebuildCost.isEmpty) }
        #expect(JunkKind.rustTarget.rebuildCost.contains("min"))
    }
}
