import Foundation

/// Turns one transcript line into what the conversation view needs. Shapes:
/// `user` (string or block content: text / image / tool_result), `assistant`
/// (one line per content block — text / thinking / tool_use — sharing a
/// `message.id`), `system` (compaction, local slash commands), and the title
/// lines `summary` / `ai-title` / `custom-title` / `last-prompt`. Everything else (attachments,
/// modes, snapshots, sidechains, meta prompts) is not part of the conversation.
enum ChatLineParser {
    struct Parsed {
        var message: ChatMessage?
        /// `message.id` of an assistant line: consecutive lines with the same
        /// id are one reply split per content block.
        var assistantID: String?
        var results: [(id: String, result: ChatToolResult)] = []
        var customTitle: String?
        var aiTitle: String?
        var summary: String?
        /// First-line title candidate when this line is a real user prompt.
        var prompt: String?
        /// Same, from a `last-prompt` line: the last fallback before "Untitled".
        var lastPrompt: String?
        var timestamp: String?
    }

    /// Type markers worth decoding; a line with none of them is skipped unparsed.
    static let wanted: [[UInt8]] = [
        "\"type\":\"user\"", "\"type\":\"assistant\"", "\"type\":\"system\"",
        "\"type\":\"summary\"", "\"type\":\"ai-title\"", "\"type\":\"custom-title\"",
        "\"type\":\"last-prompt\"",
    ].map { Array($0.utf8) }

    /// nil for malformed or uninteresting lines.
    static func parse(_ line: UnsafeRawBufferPointer) -> Parsed? {
        guard wanted.contains(where: { contains(line, $0) }) else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line.baseAddress!), count: line.count,
                        deallocator: .none)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return parse(obj)
    }

    static func parse(_ line: String) -> Parsed? {
        var line = line
        return line.withUTF8 { buf in buf.isEmpty ? nil : parse(UnsafeRawBufferPointer(buf)) }
    }

    static func parse(_ v: [String: Any]) -> Parsed? {
        var p = Parsed()
        p.timestamp = v["timestamp"] as? String
        let id = v["uuid"] as? String ?? UUID().uuidString
        let date = p.timestamp.flatMap(parseDate)
        switch v["type"] as? String {
        case "summary": p.summary = nonEmpty(v["summary"])
        case "ai-title": p.aiTitle = nonEmpty(v["aiTitle"])
        case "custom-title": p.customTitle = nonEmpty(v["customTitle"])
        case "last-prompt":
            if let text = nonEmpty(v["lastPrompt"]), case let .prompt(_, title) = ChatText.classifyUser(text) {
                p.lastPrompt = title
            }
        case "system":
            guard v["isSidechain"] as? Bool != true else { return nil }
            switch v["subtype"] as? String {
            case "compact_boundary":
                p.message = ChatMessage(id: id, role: .notice, blocks: [.text("Conversation compacted")], timestamp: date)
            case "local_command":
                if case let .notice(blocks) = ChatText.classifyUser(v["content"] as? String ?? "") {
                    p.message = ChatMessage(id: id, role: .notice, blocks: blocks, timestamp: date)
                }
            default: return nil
            }
        case "user":
            guard v["isSidechain"] as? Bool != true, v["isMeta"] as? Bool != true else { return nil }
            parseUser(v, id: id, date: date, into: &p)
        case "assistant":
            guard v["isSidechain"] as? Bool != true else { return nil }
            let message = v["message"] as? [String: Any]
            p.assistantID = message?["id"] as? String ?? id
            let blocks = (message?["content"] as? [Any] ?? []).compactMap { assistantBlock($0) }
            if let s = message?["content"] as? String, !s.isEmpty {
                p.message = ChatMessage(id: id, role: .assistant, blocks: [.text(s)], timestamp: date)
            } else if !blocks.isEmpty {
                p.message = ChatMessage(id: id, role: .assistant, blocks: blocks, timestamp: date)
            }
        default: return nil
        }
        return p
    }

    // MARK: - User

    private static func parseUser(_ v: [String: Any], id: String, date: Date?, into p: inout Parsed) {
        let content = (v["message"] as? [String: Any])?["content"]
        if v["isCompactSummary"] as? Bool == true {
            let text = (content as? String) ?? texts(content).joined(separator: "\n")
            p.message = ChatMessage(id: id, role: .notice, blocks: [
                .detail(title: "Summary of the earlier conversation", body: ChatText.cap(text, ChatText.maxText).text),
            ], timestamp: date)
            return
        }
        var raw: [String] = [], images = 0
        if let s = content as? String {
            raw = [s]
        } else if let blocks = content as? [Any] {
            for case let b as [String: Any] in blocks {
                switch b["type"] as? String {
                case "text": if let t = b["text"] as? String { raw.append(t) }
                case "image": images += 1
                case "tool_result":
                    if let tid = b["tool_use_id"] as? String { p.results.append((tid, toolResult(b))) }
                default: break
                }
            }
        }
        var display: [String] = [], notices: [ChatBlock] = []
        for text in raw {
            switch ChatText.classifyUser(text) {
            case let .prompt(d, title):
                display.append(d)
                if p.prompt == nil { p.prompt = title }
            case let .notice(blocks): notices += blocks
            case .none: break
            }
        }
        if !display.isEmpty || images > 0 {
            var blocks: [ChatBlock] = display.map { .text($0) }
            if images > 0 { blocks.append(.image(count: images)) }
            p.message = ChatMessage(id: id, role: .user, blocks: blocks, timestamp: date)
        } else if !notices.isEmpty {
            p.message = ChatMessage(id: id, role: .notice, blocks: notices, timestamp: date)
        }
    }

    private static func toolResult(_ b: [String: Any]) -> ChatToolResult {
        var images = 0
        let text: String
        if let s = b["content"] as? String {
            text = s
        } else {
            let blocks = b["content"] as? [Any] ?? []
            images = blocks.filter { ($0 as? [String: Any])?["type"] as? String == "image" }.count
            text = texts(b["content"]).joined(separator: "\n")
        }
        let clean = ChatText.strip(["system-reminder"], from: text).trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = ChatText.cap(clean, ChatText.maxResult)
        return ChatToolResult(text: capped.text, isError: b["is_error"] as? Bool == true, omitted: capped.omitted,
                              images: images)
    }

    // MARK: - Assistant

    private static func assistantBlock(_ any: Any) -> ChatBlock? {
        guard let b = any as? [String: Any] else { return nil }
        switch b["type"] as? String {
        case "text":
            guard let t = b["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .text(ChatText.cap(t, ChatText.maxText).text)
        case "thinking":
            guard let t = b["thinking"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .detail(title: "Thinking", body: ChatText.cap(t, ChatText.maxText).text)
        case "tool_use":
            let input = b["input"] as? [String: Any] ?? [:]
            let name = b["name"] as? String ?? "Tool"
            return .tool(ChatToolCall(id: b["id"] as? String ?? UUID().uuidString, name: ChatText.toolDisplayName(name),
                                      summary: ChatText.toolGist(input), input: ChatText.toolInput(input)))
        case "image": return .image(count: 1)
        default: return nil
        }
    }

    // MARK: - Helpers

    private static func texts(_ content: Any?) -> [String] {
        (content as? [Any] ?? []).compactMap { b in
            guard let b = b as? [String: Any], b["type"] as? String == "text" else { return nil }
            return b["text"] as? String
        }
    }

    private static func nonEmpty(_ v: Any?) -> String? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static func parseDate(_ s: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s))
            ?? (try? Date.ISO8601FormatStyle().parse(s))
    }

    /// Byte substring search (memmem) — the cheap pre-filter before JSON decoding.
    static func contains(_ hay: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = hay.baseAddress, hay.count >= needle.count else { return false }
        return needle.withUnsafeBytes { n in memmem(base, hay.count, n.baseAddress!, n.count) != nil }
    }
}
