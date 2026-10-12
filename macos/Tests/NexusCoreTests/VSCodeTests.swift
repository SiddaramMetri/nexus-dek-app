import Foundation
import Testing
@testable import NexusCore

// Ports of the non-#[ignore] tests in src-tauri/src/doctor/vscode.rs, plus
// temp-dir checks of the SQLite reads, VACUUM and orphan cleanup.

@Suite struct VSCodeTests {
    @Test func decodesWorkspaceFolderURI() {
        #expect(VSCodeCache.folder(fromWorkspaceJSON: #"{"folder":"file:///Users/x/Documents/VSS%20Batches/C12"}"#)
            == "/Users/x/Documents/VSS Batches/C12")
        // multi-root and remote workspaces are skipped, never guessed at
        #expect(VSCodeCache.folder(fromWorkspaceJSON: #"{"workspace":"file:///x.code-workspace"}"#) == nil)
        #expect(VSCodeCache.folder(fromWorkspaceJSON: #"{"folder":"vscode-remote://ssh/x"}"#) == nil)
        #expect(VSCodeCache.folder(fromWorkspaceJSON: "not json") == nil)
    }

    @Test func bloatThresholds() {
        #expect(VSCodeProbes.classifyBloat(10 * 1024 * 1024) == nil)
        #expect(VSCodeProbes.classifyBloat(60 * 1024 * 1024) == .yellow)
        #expect(VSCodeProbes.classifyBloat(600 * 1024 * 1024) == .red)
    }

    @Test func formatsSizes() {
        #expect(VSCodeDoctor.fmtMB(60 * 1024 * 1024) == "60 MB")
        #expect(VSCodeDoctor.fmtMB(2_415_919_104) == "2.2 GB") // 2.25 GB, round-half-even
    }

    @Test func probeIdsMatchRust() {
        #expect(VSCodeDoctor.orphans.id == "vscode_orphans")
        #expect(VSCodeDoctor.dbBloat.id == "state_db_bloat")
        #expect(VSCodeDoctor.extensionAudit.id == "extension_audit")
    }

    func meta(_ id: String, star: Bool, startup: Bool) -> ExtMeta {
        ExtMeta(id: id, display: id, publisher: String(id.split(separator: ".")[0]), star: star, startup: startup)
    }

    @Test func parsesExtensionManifest() throws {
        let m = try #require(VSCodeExtensions.parseManifest(
            #"{"name":"Continue","publisher":"Continue","activationEvents":["*","onStartupFinished"]}"#, nls: nil))
        #expect(m.id == "continue.continue")
        #expect(m.star && m.startup)
        #expect(m.display == "Continue", "falls back to title-cased name")
        let lazy = try #require(VSCodeExtensions.parseManifest(
            #"{"name":"astro","publisher":"astro-build","activationEvents":["onLanguage:astro"]}"#, nls: nil))
        #expect(!lazy.star && !lazy.startup)
        #expect(VSCodeExtensions.parseManifest(#"{"name":"no-publisher"}"#, nls: nil) == nil)

        let named = #"{"name":"git-graph","publisher":"mhutchie","displayName":"Git Graph"}"#
        #expect(VSCodeExtensions.parseManifest(named, nls: nil)?.display == "Git Graph")
        let localized = #"{"name":"vscode-docker","publisher":"ms-azuretools","displayName":"%displayName%"}"#
        #expect(VSCodeExtensions.parseManifest(localized, nls: #"{"displayName":"Docker"}"#)?.display == "Docker")
        #expect(VSCodeExtensions.parseManifest(localized, nls: nil)?.display == "Vscode Docker",
                "missing nls falls back to title-cased name")
    }

    @Test func auditsStackingAndDuplicates() {
        let metas = [
            meta("github.copilot", star: false, startup: true),
            meta("github.copilot-chat", star: false, startup: true), // same publisher → one assistant
            meta("anthropic.claude-code", star: false, startup: true),
            meta("continue.continue", star: true, startup: false),
            meta("astro-build.astro", star: false, startup: false),
            meta("astro-build.astro", star: false, startup: false), // duplicate install
        ]
        let a = VSCodeExtensions.audit(metas)
        #expect(a.total == 6)
        #expect(a.ai.count == 3, "github + anthropic + continue")
        #expect(a.star == ["continue.continue"])
        #expect(a.startup == 3)
        #expect(a.dups == ["astro-build.astro"])

        let f = VSCodeExtensions.findings(metas, canUninstall: true)
        #expect(f.count == 1 + 5, "aggregate + one row per unique extension")
        #expect(f[0].severity == .yellow && f[0].guide?.count == 2 && f[0].fix == nil)
        #expect(f[0].summary == "6 extensions · 3 activate at startup · 3 AI assistants")
        #expect(f[1].fix == "vscode_ext_rm:github.copilot")
        #expect(VSCodeExtensions.findings(metas, canUninstall: false).dropFirst().allSatisfy { $0.fix == nil })
    }

    @Test func parsesSessionCacheContract() throws {
        let raw = """
        [
          {"resource":"claude-code:/6bf3f2b8-aaaa-bbbb-cccc-000000000001","label":"Fix sidebar collapse","timing":{},"changes":[]},
          {"resource":"claude-code:/6bf3f2b8-aaaa-bbbb-cccc-000000000002","label":"Add MUI tabs"},
          {"label":"entry without resource is skipped"},
          {"resource":"claude-code:/no-label-skipped"}
        ]
        """
        let cache = try #require(VSCodeCache.parseSessionCache(raw))
        #expect(cache.titles.count == 2)
        #expect(cache.titles["6bf3f2b8-aaaa-bbbb-cccc-000000000002"] == "Add MUI tabs")
        #expect(cache.bytes == UInt64(raw.utf8.count))
        // Fail-safe: unrecognized top-level shapes are refused, never guessed at.
        #expect(VSCodeCache.parseSessionCache(#"{"not":"an array"}"#) == nil)
        #expect(VSCodeCache.parseSessionCache("garbage") == nil)
    }

    // The main process (no "Helper" in its name) must be in there — it's the
    // one that holds state.vscdb, and the one `pgrep -f` can't see.
    @Test func parsesVSCodePidsFromPs() {
        let ps = """
         1310 /Applications/Visual Studio Code.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler
        63404 /Applications/Visual Studio Code.app/Contents/MacOS/Code
        63406 /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper
          456 /Applications/Cursor.app/Contents/MacOS/Cursor
          789 /usr/libexec/secinitd
        """
        #expect(VSCodeProcess.parseVSCodePids(ps) == ["1310", "63404", "63406"])
        #expect(VSCodeProcess.parseVSCodePids("").isEmpty)
    }

    // Only VSCode's own hold blocks a VACUUM — our scan's read-only handles must not.
    @Test func onlyVSCodeHoldersBlockTheVacuum() {
        let vs = ["63404", "63406"]
        #expect(VSCodeProcess.anyHolderIsVSCode("63404\n", vscodePids: vs))
        #expect(!VSCodeProcess.anyHolderIsVSCode("74067\n900\n", vscodePids: vs), "our pid / mdworker")
        #expect(!VSCodeProcess.anyHolderIsVSCode("", vscodePids: vs), "nothing holds them")
        #expect(!VSCodeProcess.anyHolderIsVSCode("634041\n", vscodePids: vs), "no substring matches")
    }
}

@Suite struct VSCodeFilesystemTests {
    let base: URL = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        .appendingPathComponent("nexus-vscode-\(UUID().uuidString)", isDirectory: true)

    func workspace(_ name: String, folder: String?) throws -> URL {
        let dir = base.appendingPathComponent("ws/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let folder {
            let uri = "file://" + folder.replacingOccurrences(of: " ", with: "%20")
            try Data(#"{"folder":"\#(uri)"}"#.utf8).write(to: dir.appendingPathComponent("workspace.json"))
        }
        try Data(repeating: 7, count: 1000).write(to: dir.appendingPathComponent("blob.bin"))
        return dir
    }

    @Test func cleanupRemovesOnlyOrphans() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let alive = base.appendingPathComponent("alive project")
        try FileManager.default.createDirectory(at: alive, withIntermediateDirectories: true)
        let orphan = try workspace("orphan", folder: base.appendingPathComponent("deleted").path)
        let kept = try workspace("kept", folder: alive.path)
        let volume = try workspace("volume", folder: "/Volumes/Unplugged/proj")
        let plain = try workspace("plain", folder: nil)
        let root = base.appendingPathComponent("ws")

        let scan = try #require(VSCodeProbes.scanOrphans(root: root))
        #expect(scan.dirs.map(\.lastPathComponent) == ["orphan"])
        #expect(scan.bytes >= 1000)
        #expect(VSCodeProbes.orphansFinding(scan).fix == "vscode_cleanup_orphans")

        let journal = JournalCapture()
        let msg = try VSCodeProbes.cleanupOrphans(root: root, journal: journal.sink)
        #expect(msg.hasPrefix("Removed 1 orphan cache · freed"))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        for d in [kept, volume, plain] { #expect(FileManager.default.fileExists(atPath: d.path)) }
        #expect(journal.entries.map(\.action) == ["vscodeCleanupOrphans"])
        #expect(VSCodeProbes.orphansFinding(try #require(VSCodeProbes.scanOrphans(root: root))).severity == .green)
    }

    @Test func readsSessionCacheAndVacuums() throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let project = base.appendingPathComponent("my proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let ws = try workspace("abc", folder: project.path)
        let dbURL = ws.appendingPathComponent("state.vscdb")
        let db = try #require(VSCodeDB(dbURL.path, readOnly: false))
        let cache = #"[{"resource":"claude-code:/uuid-1","label":"Cached title"}]"#
        #expect(db.execute("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)") == nil)
        #expect(db.execute("INSERT INTO ItemTable VALUES ('agentSessions.model.cache', '\(cache)')") == nil)
        #expect(db.execute("CREATE TABLE junk (v BLOB)") == nil)
        #expect(db.execute("INSERT INTO junk SELECT randomblob(4096) FROM (WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 200) SELECT x FROM c)") == nil)
        #expect(db.execute("DELETE FROM junk") == nil)

        let found = try #require(VSCodeCache.sessionCache(forFolder: project.path + "/", root: base.appendingPathComponent("ws")))
        #expect(found.titles == ["uuid-1": "Cached title"])
        #expect(found.bytes == UInt64(cache.utf8.count))

        #expect((VSCodeDB.reclaimable(dbURL) ?? 0) > 100 * 4096)
        #expect(VSCodeDB.vacuum(dbURL) == nil)
        #expect(VSCodeDB.reclaimable(dbURL) == 0)
        #expect(VSCodeDB.reclaimable(base.appendingPathComponent("missing.vscdb")) == nil)
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("missing.vscdb").path),
                "read-only open never creates a file")
    }
}
