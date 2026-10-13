import Foundation
import Testing
@testable import NexusCore

/// A throwaway home folder with real files, so path resolution and the
/// project-root walk run against the filesystem.
private struct TempHome {
    let url: URL
    var path: String { url.path }

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ports-tests-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func file(_ rel: String, _ contents: String = "") throws -> String {
        let f = url.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: f, atomically: true, encoding: .utf8)
        return f.path
    }

    @discardableResult
    func dir(_ rel: String) throws -> String {
        let d = url.appendingPathComponent(rel, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.path
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

@Suite struct PortsOwnerTests {
    static let vscodeHelper = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"

    @Test func appBundleIsTheOutermostApp() {
        #expect(PortClassifier.appBundle(executable: Self.vscodeHelper) == "/Applications/Visual Studio Code.app")
        #expect(PortClassifier.appBundle(executable: "/Applications/Ollama.app/Contents/Resources/ollama")
            == "/Applications/Ollama.app")
        #expect(PortClassifier.appBundle(executable: "/opt/homebrew/opt/redis/bin/redis-server") == nil)
        #expect(PortClassifier.appBundle(executable: "Code Helper.app/x") == nil)
        #expect(PortClassifier.appName(bundlePath: "/Applications/Visual Studio Code.app") == "Visual Studio Code")
    }

    @Test func systemPrefixes() {
        #expect(PortClassifier.isSystem(executable: "/usr/libexec/rapportd"))
        #expect(PortClassifier.isSystem(executable: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"))
        #expect(PortClassifier.isSystem(executable: "/usr/sbin/sshd"))
        #expect(PortClassifier.isSystem(executable: "/sbin/launchd"))
        #expect(!PortClassifier.isSystem(executable: "/usr/bin/python3"))
        #expect(!PortClassifier.isSystem(executable: "/opt/homebrew/bin/postgres"))
    }

    @Test func classifiesSystemBeforeAppAndAppBeforeProject() throws {
        let home = try TempHome()
        defer { home.remove() }
        let proj = try home.dir("code/shopfront")
        let cc = "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"
        #expect(PortClassifier.classify(executable: cc, cwd: proj, commandLine: cc, home: home.url) == .system)
        #expect(PortClassifier.classify(executable: Self.vscodeHelper, cwd: proj, commandLine: nil, home: home.url)
            == .app(bundlePath: "/Applications/Visual Studio Code.app"))
        #expect(PortClassifier.classify(executable: "/usr/bin/python3", cwd: proj, commandLine: nil, home: home.url)
            == .project(root: proj))
        #expect(PortClassifier.classify(executable: "/opt/homebrew/bin/redis-server", cwd: "/",
                                        commandLine: "/opt/homebrew/bin/redis-server 127.0.0.1:6379", home: home.url)
            == .other)
        #expect(PortClassifier.classify(executable: nil, cwd: nil, commandLine: nil, home: home.url) == .other)
    }

    @Test func pathTokensIncludeFlagValuesAndStripQuotes() {
        #expect(PortClassifier.pathTokens(#"node --config=/a/b.json "/c/d.js", ./rel x"#) == ["/a/b.json", "/c/d.js"])
        #expect(PortClassifier.pathTokens("") == [])
    }

    @Test func cwdInsideHomeWins() throws {
        let home = try TempHome()
        defer { home.remove() }
        let cwd = try home.dir("work/site")
        let script = try home.file("Documents/api/server.js")
        #expect(PortClassifier.projectDirectory(cwd: cwd, commandLine: "node \(script)", home: home.path) == cwd)
    }

    @Test func fallsBackToCommandLineWhenCwdIsRootOrHome() throws {
        let home = try TempHome()
        defer { home.remove() }
        // node from ~/.nvm (a tool install, skipped) running a script in a project.
        let node = try home.file(".nvm/versions/node/v22/bin/node")
        let script = try home.file("Documents/aws-s3-view-data/docklyt/agent/index.js")
        let cmd = "\(node) \(script)"
        let expected = (script as NSString).deletingLastPathComponent
        #expect(PortClassifier.projectDirectory(cwd: "/", commandLine: cmd, home: home.path) == expected)
        #expect(PortClassifier.projectDirectory(cwd: home.path, commandLine: cmd, home: home.path) == expected)
        #expect(PortClassifier.projectDirectory(cwd: try home.dir("Documents"), commandLine: cmd, home: home.path) == expected)
    }

    @Test func cutsDependencyFoldersAndRejectsToolsAndLibrary() throws {
        let home = try TempHome()
        defer { home.remove() }
        let proj = try home.dir("shop")
        let next = try home.file("shop/node_modules/.bin/next")
        #expect(PortClassifier.projectDirectory(cwd: "/", commandLine: "node \(next) dev", home: home.path) == proj)
        let venvPython = try home.file("shop/.venv/bin/python")
        #expect(PortClassifier.projectDirectory(cwd: nil, commandLine: venvPython, home: home.path) == proj)
        let uvTool = try home.file(".local/share/uv/tools/headroom/bin/python")
        let support = try home.dir("Library/Application Support/Code")
        #expect(PortClassifier.projectDirectory(cwd: "/", commandLine: "\(uvTool) --user-data-dir=\(support)",
                                                home: home.path) == nil)
        // Paths that don't exist are ignored.
        #expect(PortClassifier.projectDirectory(cwd: "/", commandLine: "x \(home.path)/ghost/a.js", home: home.path) == nil)
        #expect(PortClassifier.projectDirectory(cwd: "/tmp", commandLine: "/usr/bin/python3 -m http.server", home: home.path) == nil)
    }

    @Test func projectRootIsTheGitRootWithSubAppsLifted() throws {
        let home = try TempHome()
        defer { home.remove() }
        let repo = try home.dir("Documents/rideorbit")
        try home.file("Documents/rideorbit/.git/HEAD", "ref: refs/heads/feature/maps\n")
        let script = try home.file("Documents/rideorbit/server/src/index.js")
        let owner = PortClassifier.classify(executable: "/usr/local/bin/node", cwd: "/",
                                            commandLine: "node \(script)", home: home.url)
        #expect(owner == .project(root: repo))
        #expect(GitHead.branch(atRoot: repo) == "feature/maps")
        // No git: a `frontend` next to a `backend` groups under their parent.
        let plain = try home.dir("code/rl_zoho")
        let fe = try home.dir("code/rl_zoho/frontend")
        _ = try home.dir("code/rl_zoho/backend")
        #expect(PortClassifier.classify(executable: nil, cwd: fe, commandLine: nil, home: home.url) == .project(root: plain))
    }

    @Test func gitHeadParsing() throws {
        #expect(GitHead.parseHead("ref: refs/heads/main\n") == "main")
        #expect(GitHead.parseHead("ref: refs/remotes/origin/x") == "refs/remotes/origin/x")
        #expect(GitHead.parseHead("3f2a9c1d0e4b5a6978877665544332211000ffee\n") == "3f2a9c1")
        #expect(GitHead.parseHead("garbage") == nil)
        let home = try TempHome()
        defer { home.remove() }
        // Worktree: `.git` is a file pointing at the real git dir.
        try home.file("main/.git/worktrees/wt/HEAD", "ref: refs/heads/hotfix\n")
        let wt = try home.dir("wt")
        try home.file("wt/.git", "gitdir: \(home.path)/main/.git/worktrees/wt\n")
        #expect(GitHead.branch(atRoot: wt) == "hotfix")
        #expect(GitHead.branch(atRoot: try home.dir("nogit")) == nil)
    }

    @Test func friendlySystemNames() {
        let cc = PortClassifier.systemName(command: "ControlCenter")
        #expect(cc.title == "AirPlay Receiver")
        #expect(cc.note?.contains("System Settings → General → AirDrop & Handoff") == true)
        #expect(PortClassifier.systemName(command: "rapportd") == .init(title: "Handoff & Continuity", note: nil))
        #expect(PortClassifier.systemName(command: "sharingd") == .init(title: "sharingd", note: nil))
    }
}
