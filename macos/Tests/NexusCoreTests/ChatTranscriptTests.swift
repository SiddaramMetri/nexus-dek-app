import Foundation
import Testing
@testable import NexusCore

/// A small transcript in a temp dir. Lines are hand-written; never a real ~/.claude file.
private struct TranscriptFile {
    let dir: URL
    let url: URL

    init(_ lines: [String], trailingNewline: Bool = true) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nexus-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("6676f0a6-4256-4b88-8381-b79ab8efc700.jsonl")
        try Data((lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).utf8).write(to: url)
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

private let conversation = [
    #"{"type":"summary","summary":"Fix the flaky test","leafUuid":"x"}"#,
    #"{"type":"user","uuid":"u1","timestamp":"2026-10-01T10:00:00.000Z","message":{"role":"user","content":"why is the test flaky?"}}"#,
    #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-01T10:00:05.000Z","message":{"id":"m1","content":[{"type":"text","text":"Let me look."}]}}"#,
    #"{"type":"assistant","uuid":"a2","timestamp":"2026-10-01T10:00:06.000Z","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm test"}}]}}"#,
    #"{"type":"user","uuid":"r1","timestamp":"2026-10-01T10:00:09.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"1 failed"}]}}"#,
    #"{"type":"user","uuid":"broken"#,
    #"{"type":"user","uuid":"u2","timestamp":"2026-10-01T10:05:00.000Z","message":{"content":"fix it"}}"#,
    #"{"type":"attachment","attachment":{"type":"user"}}"#,
    #"{"type":"assistant","uuid":"a3","timestamp":"2026-10-01T10:06:00.000Z","message":{"id":"m2","content":[{"type":"text","text":"Fixed."}]}}"#,
]

@Suite struct ChatReaderTests {
    @Test func pagesBackwardsWithoutSplittingReplies() throws {
        let f = try TranscriptFile(conversation)
        defer { f.cleanup() }

        let latest = try ChatReader.page(f.url, before: nil, limit: 2)
        #expect(latest.messages.map(\.id) == ["u2", "a3"])
        #expect(latest.results["t1"]?.text == "1 failed")
        #expect(latest.startOffset > 0)

        let earlier = try ChatReader.page(f.url, before: latest.startOffset, limit: 2)
        #expect(earlier.startOffset == 0)
        #expect(earlier.messages.map(\.role) == [.user, .assistant])
        // m1 arrived as two lines (text, then tool_use) — one bubble, in order.
        let reply = try #require(earlier.messages.last)
        #expect(reply.blocks.count == 2)
        #expect(reply.blocks.first == .text("Let me look."))
        guard case let .tool(call) = reply.blocks[1] else { Issue.record("no tool block"); return }
        #expect(call.summary == "npm test")

        let all = try ChatReader.page(f.url, before: nil, limit: 200)
        #expect(all.messages.map(\.id) == ["u1", "a1", "u2", "a3"])
        #expect(all.startOffset == 0)
    }

    @Test func readsAcrossChunkBoundariesAndUnterminatedLastLine() throws {
        // Lines longer than one read chunk, and no trailing newline.
        let big = String(repeating: "y", count: ChatReader.chunk + 100)
        let f = try TranscriptFile([
            #"{"type":"user","uuid":"u1","message":{"content":"first"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"id":"m","content":[{"type":"text","text":"\#(big)"}]}}"#,
            #"{"type":"user","uuid":"u2","message":{"content":"last"}}"#,
        ], trailingNewline: false)
        defer { f.cleanup() }
        let page = try ChatReader.page(f.url, before: nil, limit: 10)
        #expect(page.messages.map(\.id) == ["u1", "a1", "u2"])
        var forward = 0
        try ChatReader.linesForward(f.url) { _ in forward += 1; return true }
        #expect(forward == 3)
    }

    @Test func scanCountsMessagesAndActivity() throws {
        let f = try TranscriptFile(conversation)
        defer { f.cleanup() }
        let s = try ChatReader.scan(f.url)
        #expect(s.stats.messages == 4)
        #expect(s.stats.firstActivity == ChatLineParser.parseDate("2026-10-01T10:00:00Z"))
        #expect(s.stats.lastActivity == ChatLineParser.parseDate("2026-10-01T10:06:00Z"))
        #expect(s.summary == "Fix the flaky test")
        #expect(s.prompt == "why is the test flaky?")
    }

    @Test func emptyAndJunkFilesAreHarmless() throws {
        let f = try TranscriptFile(["not json", #"{"type":"bridge-session"}"#])
        defer { f.cleanup() }
        #expect(try ChatReader.page(f.url, before: nil, limit: 5).messages.isEmpty)
        #expect(try ChatReader.scan(f.url).stats == ChatStats(messages: 0, firstActivity: nil, lastActivity: nil))
    }
}

@Suite struct ChatTitleTests {
    @Test func titleOrderNeverBlank() throws {
        let f = try TranscriptFile(conversation)
        defer { f.cleanup() }
        #expect(ArchiverText.chatTitle(f.url, cached: nil, epoch: 0) == "Fix the flaky test")
        #expect(ArchiverText.chatTitle(f.url, cached: "VSCode label", epoch: 0) == "VSCode label")
        #expect(ArchiverText.chatTitle(f.url, cached: " — ", epoch: 0) == "Fix the flaky test")
        #expect(ArchiverText.chatTitle(f.url, cached: "two\nlines", epoch: 0) == "two lines")

        let renamed = try TranscriptFile(conversation + [#"{"type":"custom-title","customTitle":"My rename"}"#])
        defer { renamed.cleanup() }
        #expect(ArchiverText.chatTitle(renamed.url, cached: "VSCode label", epoch: 0) == "My rename")

        let promptOnly = try TranscriptFile([
            #"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"user","message":{"content":[{"type":"image"}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"x"}]}}"#,
            #"{"type":"user","message":{"content":"  the real question\nwith detail"}}"#,
        ])
        defer { promptOnly.cleanup() }
        #expect(ArchiverText.chatTitle(promptOnly.url, cached: nil, epoch: 0) == "the real question")

        let lastOnly = try TranscriptFile([
            #"{"type":"user","isMeta":true,"message":{"content":"<local-command-caveat>x</local-command-caveat>"}}"#,
            #"{"type":"last-prompt","lastPrompt":"deploy the  preview\nplease","leafUuid":"x"}"#,
        ])
        defer { lastOnly.cleanup() }
        #expect(ArchiverText.chatTitle(lastOnly.url, cached: nil, epoch: 0) == "deploy the preview")

        let empty = try TranscriptFile([#"{"type":"bridge-session"}"#])
        defer { empty.cleanup() }
        #expect(ArchiverText.chatTitle(empty.url, cached: nil, epoch: 1_784_246_400) == "Untitled chat · 17 Jul 2026")
    }

    @Test func dashIndexRowsAreTreatedAsMissing() {
        let md = "| Date | Chat | File |\n|---|---|---|\n| 1 Jan 2026 | — | a.jsonl |\n| 1 Jan 2026 | Good | b.jsonl |\n"
        #expect(ArchiverText.parseIndex(md) == ["b.jsonl": "Good"])
    }
}

@Suite struct ChatContinueTests {
    @Test func sessionIDMustBeACanonicalUUID() throws {
        let id = "6676f0a6-4256-4b88-8381-b79ab8efc700"
        #expect(ClaudeChats.sessionID(file: id + ".jsonl") == id)
        for bad in [id, id + ".json", "x" + String(id.dropFirst()) + ".jsonl", id + "; rm -rf ~.jsonl",
                    "6676f0a64256-4b88-8381-b79ab8efc700-.jsonl", "../" + id + ".jsonl", " " + id + ".jsonl",
                    "$(whoami)-4256-4b88-8381-b79ab8efc700.jsonl", ".jsonl"] {
            #expect(ClaudeChats.sessionID(file: bad) == nil, "\(bad)")
            #expect(throws: AppError.self) { try ClaudeChats.resumeCommand(file: bad) }
        }
        #expect(try ClaudeChats.resumeCommand(file: id + ".jsonl") == "claude --resume \(id)")
    }

    @Test func copyableCommandQuotesTheFolder() throws {
        let file = "6676f0a6-4256-4b88-8381-b79ab8efc700.jsonl"
        #expect(try ClaudeChats.copyableResumeCommand(file: file, folder: "/Users/me/it's here")
            == #"cd '/Users/me/it'\''s here' && claude --resume 6676f0a6-4256-4b88-8381-b79ab8efc700"#)
    }

    @Test func resumeNeedsALiveChat() {
        let file = "6676f0a6-4256-4b88-8381-b79ab8efc700.jsonl"
        #expect(ClaudeChats.resumeProblem(.live(dirName: "-Users-me-x"), file: file) == nil)
        #expect(ClaudeChats.resumeProblem(.archived(folder: "x"), file: file) != nil)
        #expect(ClaudeChats.resumeProblem(.live(dirName: "-Users-me-x"), file: "notes.jsonl") != nil)
    }

    @Test func launchFolderMustExistInsideHome() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("nexus-launch-\(UUID().uuidString)")
        let home = base.appendingPathComponent("home"), proj = home.appendingPathComponent("proj")
        let outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: proj, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appendingPathComponent("escape"), withDestinationURL: outside)
        defer { try? fm.removeItem(at: base) }

        #expect(ClaudeChats.launchProblem(folder: proj.path, home: home.path) == nil)
        #expect(ClaudeChats.launchProblem(folder: proj.path + "/", home: home.path) == nil)
        for bad in [nil, home.appendingPathComponent("gone").path] {
            #expect(ClaudeChats.launchProblem(folder: bad, home: home.path) == "The project folder no longer exists")
        }
        for bad in [outside.path, home.path, proj.path + "/../../outside", home.appendingPathComponent("escape").path,
                    "proj"] {
            #expect(ClaudeChats.launchProblem(folder: bad, home: home.path)?.contains("home folder") == true, "\(bad)")
        }
    }
}
