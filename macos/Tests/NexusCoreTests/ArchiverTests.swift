import Foundation
import Testing
@testable import NexusCore

// Ports of the non-#[ignore] tests in src-tauri/src/doctor/claude.rs, plus
// temp-dir round trips of every mutation (never the real ~/.claude).

@Suite struct ArchiverTextTests {
    @Test func titlePrefersSummary() {
        let head = """
        {"type":"queue-operation","operation":"enqueue"}
        {"type":"summary","summary":"Fix permission-driven button visibility"}
        {"type":"user","message":{"role":"user","content":"hello"}}
        """
        #expect(ArchiverText.sessionTitle(head) == "Fix permission-driven button visibility")
    }

    @Test func titleFallsBackToFirstUserMessage() {
        let head = """
        {"type":"queue-operation"}
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"  make the sidebar   collapsible please "}]}}
        """
        #expect(ArchiverText.sessionTitle(head) == "make the sidebar collapsible please")
        #expect(ArchiverText.sessionTitle("not json\n{}") == nil)
    }

    @Test func titleSkipsCommandMessages() {
        let head = """
        {"type":"user","message":{"content":"<command-name>/clear</command-name>"}}
        {"type":"user","message":{"content":"the real question"}}
        """
        #expect(ArchiverText.sessionTitle(head) == "the real question")
    }

    @Test func titleTruncatesLongMessages() {
        let long = String(repeating: "x", count: 100)
        let t = ArchiverText.sessionTitle(#"{"type":"user","message":{"content":"\#(long)"}}"#)!
        #expect(t.unicodeScalars.count <= 60 && t.hasSuffix("…"))
    }

    @Test func indexRoundtripPreservesTitles() {
        let md = ArchiverText.renderIndex(folder: "9-June", projectDirName: "-Users-x-9-June",
                                          rows: [(1_784_246_400, "A nice cached title", "abc.jsonl")])
        #expect(ArchiverText.parseIndex(md)["abc.jsonl"] == "A nice cached title")
        #expect(md.hasPrefix("# Claude chat archive — 9-June\n\nTo restore: move the file back to\n"
            + "`~/.claude/projects/-Users-x-9-June/` and restart VSCode.\n\n| Date | Chat | File |\n|---|---|---|\n"))
        #expect(md.hasSuffix("| 17 Jul 2026 | A nice cached title | abc.jsonl |\n"))
    }

    @Test func relativeTimeBuckets() {
        let now: UInt64 = 1_784_298_765
        let ago = { (d: UInt64) in
            Format.relative(Date(timeIntervalSince1970: TimeInterval(now - d)),
                            now: Date(timeIntervalSince1970: TimeInterval(now)))
        }
        #expect(ago(120) == "just now")
        #expect(ago(5 * 3_600) == "5h ago")
        #expect(ago(86_400) == "yesterday")
        #expect(ago(3 * 86_400) == "3 days ago")
        #expect(ago(21 * 86_400) == "3 weeks ago")
        #expect(ago(120 * 86_400) == "4 months ago")
    }

    @Test func dateFormatsCivil() {
        #expect(ArchiverText.formatDate(1_784_246_400) == "17 Jul 2026")
        #expect(ArchiverText.formatDate(0) == "1 Jan 1970")
        #expect(ArchiverText.formatDate(951_782_400) == "29 Feb 2000")
    }

    @Test func retentionEditPreservesOtherKeys() throws {
        let raw = #"{ "permissions": {"allow": ["x"]}, "cleanupPeriodDays": 30 }"#
        let out = try ArchiverText.withRetention(raw, days: 3650)
        let v = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        #expect(v["cleanupPeriodDays"] as? Int == 3650)
        #expect(((v["permissions"] as? [String: Any])?["allow"] as? [String])?.first == "x")
        #expect(throws: AppError.self) { try ArchiverText.withRetention("[1,2]", days: 5) }
        #expect(throws: AppError.self) { try ArchiverText.withRetention("not json", days: 5) }
    }

    @Test func retentionDaysReadsIntegersOnly() {
        #expect(ArchiverText.retentionDays(#"{"cleanupPeriodDays": 99}"#) == 99)
        #expect(ArchiverText.retentionDays(#"{"cleanupPeriodDays": 9.5}"#) == nil)
        #expect(ArchiverText.retentionDays(#"{"cleanupPeriodDays": true}"#) == nil)
        #expect(ArchiverText.retentionDays("") == nil)
    }

    @Test func parsesJournalLines() throws {
        let e = try #require(Journal.parse(
            #"{"tsEpoch":1784298765,"action":"archive","project":"9-June","moved":12,"skipped":0}"#))
        #expect(e.action == "archive")
        #expect(e.tsEpoch == 1_784_298_765)
        #expect(e.detail.contains("project 9-June") && e.detail.contains("moved 12"))
        #expect(Journal.parse("not json") == nil)
        #expect(Journal.parse(#"{"noAction":true}"#) == nil)
    }

    @Test func validatesNames() {
        #expect((try? ArchiverText.validateName("-Users-x-proj")) != nil)
        #expect(throws: AppError.self) { try ArchiverText.validateName("../etc") }
        #expect(throws: AppError.self) { try ArchiverText.validateName("") }
        #expect((try? ArchiverText.validateJsonl("a.jsonl")) != nil)
        #expect(throws: AppError.self) { try ArchiverText.validateJsonl("../a.jsonl") }
        #expect(throws: AppError.self) { try ArchiverText.validateJsonl("a.txt") }
    }

    @Test func encodesEveryNonAlphanumericAsDash() {
        #expect(ArchiverText.encodeSegment("VSS Batches") == "VSS-Batches")
        #expect(ArchiverText.encodeSegment("Draw.io") == "Draw-io")
        #expect(ArchiverText.encodeSegment("nexus_fe") == "nexus-fe")
        #expect(ArchiverText.encodeSegment("9-June") == "9-June")
    }

    @Test func fallbackDisplayStripsEncodedHome() {
        let home = ProcessInfo.processInfo.environment["HOME"]!
        let dir = "\(ArchiverText.encodeSegment(home))-Documents-Foo-Bar"
        #expect(ArchiverText.fallbackDisplay(dir, home: home) == "Documents-Foo-Bar")
        #expect(ArchiverText.fallbackDisplay("-Volumes-X-proj", home: home) == "Volumes-X-proj")
    }

    // Real-fs decode (read-only walk): HOME itself roundtrips through the encoding.
    @Test func decodesEncodedHome() {
        let home = ProcessInfo.processInfo.environment["HOME"]!
        let encoded = home.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
        #expect(ArchiverText.decodeProjectPath(encoded) == home)
    }

    @Test func olderThanFilter() {
        let now: UInt64 = 1_000_000_000
        let at = { (d: UInt64) in ArchivedChat(file: "\(d).jsonl", epoch: now - d * 86_400, title: "\(d)d") }
        let chats = [at(0), at(3), at(10), at(40)]
        #expect(ArchivedChat.olderThan(chats, days: 0, now: now).count == 4)
        #expect(ArchivedChat.olderThan(chats, days: 7, now: now).map(\.title) == ["10d", "40d"])
        #expect(ArchivedChat.olderThan(chats, days: 30, now: now).map(\.title) == ["40d"])
        #expect(ArchivedChat.olderThan([at(0), at(3)], days: 7, now: now).isEmpty)
    }

    @Test func rowsListLiveThenOrphansAndHideEmpty() {
        let p = { (dir: String, n: Int) in
            ClaudeProject(dirName: dir, displayName: dir, realPath: nil, sessions: n, totalBytes: 0,
                          newestEpoch: nil, cacheBytes: nil)
        }
        let chat = ArchivedChat(file: "a.jsonl", epoch: 1, title: "t")
        let rows = ArchiverRow.build(
            projects: [p("-a", 2), p("-empty", 0), p("-b", 0)],
            archived: [ArchivedProject(folder: "b", dirName: "-b", totalBytes: 1, chats: [chat]),
                       ArchivedProject(folder: "gone", dirName: nil, totalBytes: 1, chats: [chat])])
        #expect(rows.map(\.id) == ["-a", "-b", "orphan:gone"])
        #expect(rows[1].archived?.folder == "b")
        #expect(rows[0].subtitle == "original folder not found")
    }
}

/// Captures journal lines instead of writing the real journal.
final class JournalCapture: @unchecked Sendable {
    var entries: [(action: String, fields: [String: Any])] = []
    var sink: ArchiverFS.JournalSink { { [self] a, f in entries.append((a, f)) } }
}

/// A throwaway Claude + archive layout under the temp dir. The project dir name
/// is the Claude encoding of a real temp folder, so path decoding works.
struct ArchiverSandbox {
    let base: URL
    let realProject: URL
    let dirName: String
    let store: ArchiverStore
    let journal = JournalCapture()

    init() throws {
        let fm = FileManager.default
        base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("nexus-archiver-\(UUID().uuidString)", isDirectory: true)
        realProject = base.appendingPathComponent("real/my proj", isDirectory: true)
        try fm.createDirectory(at: realProject, withIntermediateDirectories: true)
        dirName = ArchiverText.encodeSegment(realProject.path)
        let projects = base.appendingPathComponent("projects", isDirectory: true)
        try fm.createDirectory(at: projects.appendingPathComponent(dirName), withIntermediateDirectories: true)
        store = ArchiverStore(projectsDir: projects, archiveRoot: base.appendingPathComponent("archive"),
                              settingsFile: base.appendingPathComponent("settings.json"),
                              home: "/nonexistent-home", workspaceStorage: base.appendingPathComponent("ws"),
                              journal: journal.sink)
    }

    var liveDir: URL { store.projectsDir.appendingPathComponent(dirName) }
    var archiveDir: URL { store.archiveRoot.appendingPathComponent("my proj") }

    func chat(_ name: String, daysOld: Double, title: String, in dir: URL? = nil) throws {
        let url = (dir ?? liveDir).appendingPathComponent(name)
        try Data(#"{"type":"user","message":{"content":"\#(title)"}}"#.utf8).write(to: url)
        let date = Date().addingTimeInterval(-daysOld * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

@Suite struct ArchiverStoreTests {
    @Test func listsProjectsWithDecodedNames() throws {
        let sb = try ArchiverSandbox()
        defer { sb.cleanup() }
        try sb.chat("a.jsonl", daysOld: 1, title: "one")
        try sb.chat("b.jsonl", daysOld: 2, title: "two")
        let p = try #require(try sb.store.listProjects().first)
        #expect(p.displayName == "my proj")
        #expect(p.realPath == sb.realProject.path)
        #expect(p.sessions == 2 && p.totalBytes > 0 && p.cacheBytes == nil)
        #expect(try sb.store.sessions(sb.dirName).map(\.title) == ["one", "two"])
    }

    @Test func archivePreviewThenApplyMovesOnlyOldChats() throws {
        let sb = try ArchiverSandbox()
        defer { sb.cleanup() }
        try sb.chat("old1.jsonl", daysOld: 40, title: "older")
        try sb.chat("old2.jsonl", daysOld: 35, title: "old")
        try sb.chat("new.jsonl", daysOld: 1, title: "fresh")

        let preview = try sb.store.archive(sb.dirName, cutoffDays: 30, apply: false)
        #expect(preview.candidates == ["old1.jsonl", "old2.jsonl"]) // oldest first
        #expect(preview.moved == 0)
        #expect(!FileManager.default.fileExists(atPath: sb.archiveDir.path), "dry-run touches nothing")
        #expect(sb.journal.entries.isEmpty)

        let res = try sb.store.archive(sb.dirName, cutoffDays: 30, apply: true)
        #expect(res.moved == 2 && res.skipped.isEmpty)
        #expect(FileManager.default.fileExists(atPath: sb.archiveDir.appendingPathComponent("old1.jsonl").path))
        #expect(FileManager.default.fileExists(atPath: sb.liveDir.appendingPathComponent("new.jsonl").path))
        let index = try String(contentsOf: sb.archiveDir.appendingPathComponent("INDEX.md"), encoding: .utf8)
        #expect(ArchiverText.parseIndex(index) == ["old1.jsonl": "older", "old2.jsonl": "old"])
        #expect(sb.journal.entries.map(\.action) == ["archive"])
        #expect(sb.journal.entries[0].fields["project"] as? String == "my proj")
        #expect(sb.journal.entries[0].fields["moved"] as? Int == 2)
    }

    @Test func archiveNeverOverwritesAndRejectsBadNames() throws {
        let sb = try ArchiverSandbox()
        defer { sb.cleanup() }
        try FileManager.default.createDirectory(at: sb.archiveDir, withIntermediateDirectories: true)
        try sb.chat("dup.jsonl", daysOld: 1, title: "live copy")
        try sb.chat("dup.jsonl", daysOld: 1, title: "archived copy", in: sb.archiveDir)
        let res = try sb.store.archiveFiles(sb.dirName, ["dup.jsonl", "../x.jsonl", "missing.jsonl"])
        #expect(res.done == 0)
        #expect(res.skipped == ["dup.jsonl", "../x.jsonl", "missing.jsonl"])
        #expect(throws: AppError.self) { try sb.store.archiveFiles("../etc", ["a.jsonl"]) }
        #expect(throws: AppError.self) { try sb.store.archiveFiles("-no-such-project", ["a.jsonl"]) }
    }

    @Test func archivedRestoreAndDelete() throws {
        let sb = try ArchiverSandbox()
        defer { sb.cleanup() }
        for n in ["a", "b", "c"] { try sb.chat("\(n).jsonl", daysOld: 5, title: n) }
        _ = try sb.store.archiveFiles(sb.dirName, ["a.jsonl", "b.jsonl", "c.jsonl"])

        // An orphan folder: no live project maps to it.
        let orphan = sb.store.archiveRoot.appendingPathComponent("gone")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try sb.chat("z.jsonl", daysOld: 9, title: "z", in: orphan)

        let archived = try sb.store.archived()
        #expect(archived.map(\.folder) == ["gone", "my proj"])
        #expect(archived[0].dirName == nil)
        #expect(archived[1].dirName == sb.dirName && archived[1].chats.count == 3)

        let restored = try sb.store.restore(sb.dirName, ["a.jsonl"])
        #expect(restored.done == 1)
        #expect(try sb.store.sessions(sb.dirName).map(\.file) == ["a.jsonl"])

        let deleted = try sb.store.delete("my proj", ["b.jsonl", "nope.jsonl"])
        #expect(deleted.done == 1 && deleted.skipped == ["nope.jsonl"])
        let index = try String(contentsOf: sb.archiveDir.appendingPathComponent("INDEX.md"), encoding: .utf8)
        #expect(ArchiverText.parseIndex(index).keys.sorted() == ["c.jsonl"])
        #expect(index.contains("`~/.claude/projects/\(sb.dirName)/`"))

        let live = try sb.store.deleteLive(sb.dirName, ["a.jsonl"])
        #expect(live.done == 1)
        #expect(try sb.store.sessions(sb.dirName).isEmpty)
        #expect(sb.journal.entries.map(\.action) == ["archive", "restore", "delete", "deleteLive"])
        #expect(throws: AppError.self) { try sb.store.delete("no-such-folder", ["a.jsonl"]) }
    }

    @Test func retentionWritesBackupAndPreservesKeys() throws {
        let sb = try ArchiverSandbox()
        defer { sb.cleanup() }
        #expect(sb.store.settings().cleanupPeriodDays == nil)
        #expect(throws: AppError.self) { try sb.store.setRetention(90) } // no settings.json → refuse
        try Data(#"{"model":"opus","cleanupPeriodDays":30}"#.utf8).write(to: sb.store.settingsFile)
        try sb.store.setRetention(365)
        #expect(sb.store.settings().cleanupPeriodDays == 365)
        let raw = try String(contentsOf: sb.store.settingsFile, encoding: .utf8)
        #expect(raw.contains("opus"))
        let bak = try String(contentsOf: sb.base.appendingPathComponent("settings.json.bak"), encoding: .utf8)
        #expect(bak.contains("\"cleanupPeriodDays\":30"))
        try Data("[]".utf8).write(to: sb.store.settingsFile)
        #expect(throws: AppError.self) { try sb.store.setRetention(10) }
        #expect(sb.journal.entries.map(\.action) == ["setRetention"])
    }

    @Test func autoArchiveAllSummarizes() throws {
        let sb = try ArchiverSandbox()
        defer { sb.cleanup() }
        try sb.chat("new.jsonl", daysOld: 1, title: "fresh")
        #expect(ClaudeArchiver.autoArchiveAll(store: sb.store, cutoffDays: 30) == nil)
        #expect(sb.journal.entries.isEmpty, "untouched projects get no journal churn")
        try sb.chat("old.jsonl", daysOld: 60, title: "stale")
        #expect(ClaudeArchiver.autoArchiveAll(store: sb.store, cutoffDays: 30) == "Archived 1 old chat across 1 project")
    }
}
