import Foundation
import Testing
@testable import NexusCore

// Hand-written transcript lines covering every shape `ChatLineParser` handles.
// Real transcripts are never read here.

@Suite struct ChatParserTests {
    private func parse(_ line: String) -> ChatLineParser.Parsed? { ChatLineParser.parse(line) }

    @Test func plainPromptIsAUserBubbleAndTitle() throws {
        let p = try #require(parse(#"{"type":"user","uuid":"u1","timestamp":"2026-10-01T10:00:00.000Z","message":{"role":"user","content":"  fix the   login bug\nand add a test"}}"#))
        let m = try #require(p.message)
        #expect(m.role == .user && m.id == "u1")
        #expect(m.blocks == [.text("fix the   login bug\nand add a test")])
        #expect(p.prompt == "fix the login bug")
        #expect(m.timestamp == ChatLineParser.parseDate("2026-10-01T10:00:00Z"))
    }

    @Test func wrappersAreStrippedFromPrompts() throws {
        let line = #"{"type":"user","message":{"content":[{"type":"text","text":"<system-reminder>context</system-reminder>"},{"type":"text","text":"<ide_opened_file>a.ts</ide_opened_file>real ask"}]}}"#
        let p = try #require(parse(line))
        #expect(p.message?.blocks == [.text("real ask")])
        #expect(p.prompt == "real ask")
    }

    @Test func imageOnlyPromptHasNoTitle() throws {
        let p = try #require(parse(#"{"type":"user","message":{"content":[{"type":"image","source":{"type":"base64","data":"AAAA"}}]}}"#))
        #expect(p.message?.role == .user)
        #expect(p.message?.blocks == [.image(count: 1)])
        #expect(p.prompt == nil)
    }

    @Test func toolResultsAreCollectedNotShown() throws {
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":[{"type":"text","text":"boom<system-reminder>x</system-reminder>"},{"type":"image"}]}]}}"#
        let p = try #require(parse(line))
        #expect(p.message == nil && p.prompt == nil)
        #expect(p.results.count == 1)
        #expect(p.results[0].id == "t1")
        #expect(p.results[0].result == ChatToolResult(text: "boom", isError: true, omitted: 0, images: 1))
    }

    @Test func longToolResultsAreCapped() throws {
        let big = String(repeating: "x", count: ChatText.maxResult + 10)
        let p = try #require(parse(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"\#(big)"}]}}"#))
        #expect(p.results[0].result.text.count == ChatText.maxResult)
        #expect(p.results[0].result.omitted == 10)
    }

    @Test func metaSidechainAndCaveatLinesAreSkipped() {
        #expect(parse(#"{"type":"user","isMeta":true,"message":{"content":"Caveat: the messages below"}}"#) == nil)
        #expect(parse(#"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"sub"}]}}"#) == nil)
        let caveat = parse(#"{"type":"user","message":{"content":"<local-command-caveat>Caveat</local-command-caveat>"}}"#)
        #expect(caveat?.message == nil && caveat?.prompt == nil)
    }

    @Test func slashCommandsAndOutputBecomeNotices() throws {
        let cmd = try #require(parse(#"{"type":"user","message":{"content":"<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>opus</command-args>"}}"#))
        #expect(cmd.message?.role == .notice)
        #expect(cmd.message?.blocks == [.text("Ran /model opus")])
        #expect(cmd.prompt == nil)
        let out = try #require(parse(#"{"type":"user","message":{"content":"<local-command-stdout>Set model to opus</local-command-stdout>"}}"#))
        #expect(out.message?.blocks == [.detail(title: "Command output", body: "Set model to opus")])
        let bash = try #require(parse(#"{"type":"user","message":{"content":"<bash-input>ls -la</bash-input>"}}"#))
        #expect(bash.message?.blocks == [.text("Ran ! ls -la")])
    }

    @Test func assistantBlocks() throws {
        let text = try #require(parse(#"{"type":"assistant","uuid":"a1","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"Done."}]}}"#))
        #expect(text.assistantID == "msg_1")
        #expect(text.message?.role == .assistant)
        #expect(text.message?.blocks == [.text("Done.")])

        let think = try #require(parse(#"{"type":"assistant","message":{"id":"msg_1","content":[{"type":"thinking","thinking":"hmm"}]}}"#))
        #expect(think.message?.blocks == [.detail(title: "Thinking", body: "hmm")])

        let blank = try #require(parse(#"{"type":"assistant","message":{"id":"msg_1","content":[{"type":"text","text":"  \n"}]}}"#))
        #expect(blank.message == nil)
    }

    @Test func toolCallsAreCompactNotJSON() throws {
        let p = try #require(parse(#"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm test\nnpm run lint","description":"Run tests","timeout":5000}}]}}"#))
        guard case let .tool(call)? = p.message?.blocks.first else { Issue.record("no tool block"); return }
        #expect(call.id == "t1" && call.name == "Bash" && call.summary == "npm test")
        #expect(call.input == "command:\nnpm test\nnpm run lint\ndescription: Run tests\ntimeout: 5000")
        #expect(!call.input.contains("{"))

        let mcp = try #require(parse(#"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"t2","name":"mcp__claude-in-chrome__navigate","input":{"url":"https://example.com","tabId":3}}]}}"#))
        guard case let .tool(nav)? = mcp.message?.blocks.first else { Issue.record("no tool block"); return }
        #expect(nav.name == "navigate (claude-in-chrome)" && nav.summary == "https://example.com")
    }

    @Test func titleLinesAndSystemNotices() throws {
        #expect(parse(#"{"type":"summary","summary":" Fix the sidebar ","leafUuid":"x"}"#)?.summary == "Fix the sidebar")
        #expect(parse(#"{"type":"ai-title","aiTitle":"Sidebar work"}"#)?.aiTitle == "Sidebar work")
        #expect(parse(#"{"type":"custom-title","customTitle":"Mine"}"#)?.customTitle == "Mine")
        #expect(parse(#"{"type":"summary","summary":"  "}"#)?.summary == nil)

        let compact = try #require(parse(#"{"type":"system","subtype":"compact_boundary","content":"Conversation compacted"}"#))
        #expect(compact.message?.role == .notice)
        #expect(parse(#"{"type":"system","subtype":"turn_duration","durationMs":5}"#) == nil)

        let summary = try #require(parse(#"{"type":"user","isCompactSummary":true,"message":{"content":"Earlier we fixed X."}}"#))
        #expect(summary.message?.blocks == [.detail(title: "Summary of the earlier conversation", body: "Earlier we fixed X.")])
        #expect(summary.prompt == nil)
    }

    @Test func malformedAndUninterestingLinesAreSkipped() {
        for line in ["", "not json", "{\"type\":\"user\"", #"["type","user"]"#, #"{"type":"user","message":5}"#,
                     #"{"type":"attachment","attachment":{"type":"user"}}"#, #"{"type":"file-history-snapshot"}"#,
                     #"{"type":"bridge-session"}"#] {
            #expect(parse(line)?.message == nil, "\(line)")
            #expect(parse(line)?.prompt == nil, "\(line)")
        }
    }

    @Test func interruptsAndImageMarkers() throws {
        let stop = try #require(parse(#"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#))
        #expect(stop.message?.role == .notice && stop.prompt == nil)
        let img = try #require(parse(#"{"type":"user","message":{"content":[{"type":"image"},{"type":"text","text":"[Image #3] fix this layout"}]}}"#))
        #expect(img.prompt == "fix this layout")
        #expect(img.message?.blocks == [.text("[Image #3] fix this layout"), .image(count: 1)])
        let marker = try #require(parse(#"{"type":"user","message":{"content":"<artifact-content-authored-by-others/>\nreview it"}}"#))
        #expect(marker.prompt == "review it")
    }

    @Test func pastedContentKeepsTheTypedLineAsTitle() throws {
        let line = #"{"type":"user","message":{"content":"<pasted_content id=\"a\">log line 1\nlog line 2</pasted_content id=\"a\">\nwhy does this fail?"}}"#
        let p = try #require(parse(line))
        #expect(p.prompt == "why does this fail?")
        #expect(p.message?.blocks == [.text("log line 1\nlog line 2\nwhy does this fail?")])
    }
}

@Suite struct ChatTextTests {
    @Test func splitsFencedCode() {
        let s = "Run this:\n\n```bash\nnpm test\n```\nThen `check` it.\n```\nunclosed"
        #expect(ChatText.segments(s) == [
            .prose("Run this:"), .code(language: "bash", code: "npm test"),
            .prose("Then `check` it."), .code(language: "", code: "unclosed"),
        ])
        #expect(ChatText.segments("plain") == [.prose("plain")])
        #expect(ChatText.segments("\n\n").isEmpty)
    }

    @Test func stripsWrapperTags() {
        #expect(ChatText.strip(["system-reminder"], from: "a<system-reminder>x</system-reminder>b") == "ab")
        #expect(ChatText.strip(["system-reminder"], from: "a<system-reminder>never closed") == "a")
        #expect(ChatText.inner("command-name", in: "<command-name>/clear</command-name>") == "/clear")
    }

    @Test func gistPrefersTellingKeys() {
        #expect(ChatText.toolGist(["file_path": "/a/b.swift", "old_string": "x"]) == "/a/b.swift")
        #expect(ChatText.toolGist(["zeta": "last", "alpha": "\n\nfirst line\nsecond"]) == "first line")
        #expect(ChatText.toolGist(["n": 3]).isEmpty)
    }
}
