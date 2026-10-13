import Foundation

/// Pure text helpers for transcripts: the wrapper tags Claude Code puts around
/// prompts, tool-input gists, code-fence splitting and caps. No I/O.
enum ChatText {
    /// Context Claude Code injects into a prompt — never part of what the user typed.
    static let contextTags = [
        "system-reminder", "ide_selection", "ide_opened_file", "ide_diagnostics",
        "browser_instruction", "local-command-caveat", "user-prompt-submit-hook",
    ]

    static let maxText = 60_000
    static let maxResult = 4_000
    static let maxInputValue = 2_000

    // MARK: - Tags

    /// Text between `<tag …>` and `</tag…>` (first occurrence), trimmed.
    static func inner(_ tag: String, in s: String) -> String? {
        guard let open = s.range(of: "<" + tag),
              let openEnd = s[open.upperBound...].firstIndex(of: ">") else { return nil }
        let body = s[s.index(after: openEnd)...]
        let end = body.range(of: "</" + tag)?.lowerBound ?? body.endIndex
        return body[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove every `<tag …>…</tag…>` block of the given tags. An unclosed
    /// block runs to the end of the string.
    static func strip(_ tags: [String], from s: String) -> String {
        var out = s
        for tag in tags {
            while let open = out.range(of: "<" + tag + ">") ?? out.range(of: "<" + tag + " ") {
                guard let close = out[open.upperBound...].range(of: "</" + tag) else {
                    out.removeSubrange(open.lowerBound...)
                    break
                }
                let closeEnd = out[close.upperBound...].firstIndex(of: ">").map { out.index(after: $0) } ?? out.endIndex
                out.removeSubrange(open.lowerBound..<closeEnd)
            }
        }
        return out
    }

    /// `<pasted_content id="x">BODY</pasted_content id="x">` blocks: the text
    /// typed around them, the pasted bodies, and a display form with the tags
    /// removed but the bodies kept.
    static func splitPasted(_ s: String) -> (typed: String, pasted: [String], display: String) {
        var typed = "", display = "", pasted: [String] = []
        var rest = Substring(s)
        while let open = rest.range(of: "<pasted_content") {
            typed += rest[..<open.lowerBound]
            display += rest[..<open.lowerBound]
            guard let openEnd = rest[open.upperBound...].firstIndex(of: ">") else { rest = rest[open.lowerBound...]; break }
            let body = rest[rest.index(after: openEnd)...]
            let close = body.range(of: "</pasted_content")
            let text = body[..<(close?.lowerBound ?? body.endIndex)].trimmingCharacters(in: .newlines)
            pasted.append(text)
            display += text
            guard let close, let closeEnd = body[close.upperBound...].firstIndex(of: ">") else { rest = ""; break }
            rest = body[body.index(after: closeEnd)...]
        }
        typed += rest
        display += rest
        return (typed, pasted, display)
    }

    // MARK: - Prompts

    /// What a user text turns into: a prompt bubble, a notice, or nothing.
    enum UserText: Equatable {
        case prompt(display: String, title: String?)
        case notice([ChatBlock])
        case none
    }

    static func classifyUser(_ raw: String) -> UserText {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return .none }
        if s.hasPrefix("<command-name>") || s.hasPrefix("<command-message>") {
            let name = inner("command-name", in: s) ?? "/" + (inner("command-message", in: s) ?? "command")
            let args = inner("command-args", in: s) ?? ""
            return .notice([.text("Ran " + oneLine(args.isEmpty ? name : name + " " + args, 120))])
        }
        if s.hasPrefix("<local-command-stdout>") || s.hasPrefix("<bash-stdout>") || s.hasPrefix("<bash-stderr>") {
            let out = strip(["bash-stderr"], from: inner("local-command-stdout", in: s) ?? inner("bash-stdout", in: s) ?? "")
                + (inner("bash-stderr", in: s).map { "\n" + $0 } ?? "")
            let body = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? .none : .notice([.detail(title: "Command output", body: cap(body, maxResult).text)])
        }
        if s.hasPrefix("<bash-input>") {
            return .notice([.text("Ran ! " + oneLine(inner("bash-input", in: s) ?? "", 120))])
        }
        if s.hasPrefix("<local-command-caveat>") { return .none }
        if s.hasPrefix("[Request interrupted by user") { return .notice([.text("Interrupted")]) }
        if s.hasPrefix("<task-notification>") {
            let summary = inner("summary", in: s).map { oneLine($0, 160) }
            return .notice([.text(summary ?? "Background task update")])
        }
        if s.hasPrefix("Another Claude session sent a message:") {
            let body = s.dropFirst("Another Claude session sent a message:".count)
            let text = strip(["system-reminder"], from: String(body))
                .replacingOccurrences(of: #"</?[a-z][a-z0-9_-]*(\s[^>]*)?>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .notice([.detail(title: "Message from another session", body: cap(text, maxText).text)])
        }
        let cleaned = strip(contextTags, from: s)
        let parts = splitPasted(cleaned)
        let display = parts.display.trimmingCharacters(in: .whitespacesAndNewlines)
        if display.isEmpty { return .none }
        // "[Image #2] fix this" titles as "fix this"; self-closing marker tags never title.
        let typed = parts.typed.replacingOccurrences(of: #"\[Image #\d+\]|<[a-z][a-z0-9_-]*\s*/>"#, with: "",
                                                     options: .regularExpression)
        let title = firstLine(typed) ?? parts.pasted.lazy.compactMap(firstLine).first
        return .prompt(display: cap(display, maxText).text, title: title.map { ArchiverText.truncate($0, 60) })
    }

    /// First non-blank line, trimmed.
    static func firstLine(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    static func oneLine(_ s: String, _ max: Int) -> String { ArchiverText.truncate(s, max) }

    static func cap(_ s: String, _ max: Int) -> (text: String, omitted: Int) {
        guard s.count > max else { return (s, 0) }
        return (String(s.prefix(max)), s.count - max)
    }

    // MARK: - Tools

    /// `mcp__claude-in-chrome__navigate` → "navigate (claude-in-chrome)".
    static func toolDisplayName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return name }
        return parts.dropFirst().joined(separator: "__") + " (" + parts[0] + ")"
    }

    /// Input keys that best say what a call did, most telling first.
    static let gistKeys = [
        "command", "file_path", "notebook_path", "path", "pattern", "url", "query",
        "description", "prompt", "action", "skill", "subject", "to", "text", "code", "function",
    ]

    static func toolGist(_ input: [String: Any]) -> String {
        for key in gistKeys {
            if let v = input[key] as? String, let line = firstLine(v) { return oneLine(line, 140) }
        }
        for key in input.keys.sorted() {
            if let v = input[key] as? String, let line = firstLine(v) { return oneLine(line, 140) }
        }
        return ""
    }

    /// Readable `key: value` lines — strings as-is, nested values as compact
    /// JSON — so the expanded row never shows a raw JSON object.
    static func toolInput(_ input: [String: Any]) -> String {
        let lines = input.keys.sorted().map { key -> String in
            let value: String
            switch input[key] {
            case let s as String: value = cap(s, maxInputValue).text
            case let n as NSNumber: value = n.stringValue
            case let v?:
                let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
                value = cap(data.map { String(decoding: $0, as: UTF8.self) } ?? "", maxInputValue).text
            case nil: value = ""
            }
            return value.contains("\n") ? "\(key):\n\(value)" : "\(key): \(value)"
        }
        return cap(lines.joined(separator: "\n"), maxInputValue * 3).text
    }

    // MARK: - Markdown

    /// Split on ``` fences. An unclosed fence runs to the end.
    static func segments(_ text: String) -> [ChatSegment] {
        var out: [ChatSegment] = []
        var prose: [Substring] = [], code: [Substring] = []
        var language: String?
        func flushProse() {
            let s = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !s.trimmingCharacters(in: .whitespaces).isEmpty { out.append(.prose(s)) }
            prose = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lang = language {
                    out.append(.code(language: lang, code: code.joined(separator: "\n")))
                    code = []
                    language = nil
                } else {
                    flushProse()
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            } else if language != nil {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if let lang = language { out.append(.code(language: lang, code: code.joined(separator: "\n"))) }
        flushProse()
        return out
    }
}
