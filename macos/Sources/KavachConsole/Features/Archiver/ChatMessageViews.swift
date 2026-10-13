import KavachCore
import SwiftUI

/// One transcript message: user bubbles on the right with an accent tint,
/// Claude's replies on the left on a neutral fill, tool calls and thinking as
/// muted collapsible rows, notices centered.
struct ChatMessageView: View {
    let message: ChatMessage
    let results: [String: ChatToolResult]
    @Binding var expanded: Set<String>

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 56)
                VStack(alignment: .trailing, spacing: 4) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in userBlock(block) }
                    }
                    .bubble(Color.accentColor.opacity(0.14))
                    timestamp
                }
            }
        case .assistant:
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(message.blocks.enumerated()), id: \.offset) { i, block in assistantBlock(block, key(i)) }
                    timestamp
                }
                Spacer(minLength: 56)
            }
        case .notice:
            VStack(spacing: 6) {
                ForEach(Array(message.blocks.enumerated()), id: \.offset) { i, block in noticeBlock(block, key(i)) }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func key(_ i: Int) -> String { "\(message.id)#\(i)" }

    @ViewBuilder
    private var timestamp: some View {
        if let date = message.timestamp {
            Text(Format.time(date)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func userBlock(_ block: ChatBlock) -> some View {
        switch block {
        case let .text(t): ChatRichText(text: t)
        case let .image(n): ImageChip(count: n)
        case let .tool(call): Text(call.name).font(.callout)
        case let .detail(title, _): Text(title).font(.callout)
        }
    }

    @ViewBuilder
    private func assistantBlock(_ block: ChatBlock, _ key: String) -> some View {
        switch block {
        case let .text(t): ChatRichText(text: t).bubble(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
        case let .tool(call):
            ChatToolRow(call: call, result: results[call.id], expanded: isOn(call.id)) { toggle(call.id) }
        case let .detail(title, body):
            ChatDetailRow(title: title, text: body, expanded: isOn(key)) { toggle(key) }
        case let .image(n): ImageChip(count: n)
        }
    }

    @ViewBuilder
    private func noticeBlock(_ block: ChatBlock, _ key: String) -> some View {
        switch block {
        case let .text(t):
            Text(t).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
        case let .detail(title, body):
            ChatDetailRow(title: title, text: body, expanded: isOn(key)) { toggle(key) }.frame(maxWidth: 520)
        case let .tool(call): Text(call.name).font(.caption).foregroundStyle(.secondary)
        case let .image(n): ImageChip(count: n)
        }
    }

    private func isOn(_ key: String) -> Bool { expanded.contains(key) }
    private func toggle(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }
}

private extension View {
    func bubble(_ fill: Color) -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(fill, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ImageChip: View {
    let count: Int
    var body: some View {
        Label(count == 1 ? "Image" : "\(count) images", systemImage: "photo")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// Inline markdown (bold, italics, `code`, links) with whitespace kept, and
/// fenced code blocks in a monospaced box that scrolls sideways.
struct ChatRichText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ClaudeChats.segments(text).enumerated()), id: \.offset) { _, seg in
                switch seg {
                case let .prose(s):
                    Text(Self.markdown(s)).font(.body).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case let .code(language, code):
                    CodeBox(language: language, code: code)
                }
            }
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        // Inline-only parsing shows "## Heading" literally; render headings bold instead.
        let text = s.replacingOccurrences(of: #"(?m)^#{1,6}[ \t]+(.+?)[ \t]*$"#, with: "**$1**", options: .regularExpression)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(s)
    }
}

struct CodeBox: View {
    var language = ""
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !language.isEmpty {
                Text(language).font(.caption2).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.vertical, 2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// Shared chrome for the muted collapsible rows (tool calls, thinking, outputs).
private struct CollapsibleRow<Label: View, Content: View>: View {
    let expanded: Bool
    let toggle: () -> Void
    @ViewBuilder let label: () -> Label
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10)
                    label()
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if expanded { content() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// "Bash · `npm test`" — expands to the readable input and the (capped) output.
struct ChatToolRow: View {
    let call: ChatToolCall
    let result: ChatToolResult?
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        CollapsibleRow(expanded: expanded, toggle: toggle) {
            Image(systemName: symbol).font(.caption)
            Text(call.name).font(.callout.weight(.medium)).lineLimit(1).layoutPriority(1)
            if !call.summary.isEmpty {
                Text(call.summary).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            }
            if result?.isError == true {
                Label("Error", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).fixedSize()
            }
        } content: {
            if !call.input.isEmpty { CodeBox(code: call.input) }
            if let result { ToolOutput(result: result) } else {
                Text("No output recorded").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .help(call.summary)
    }

    private var symbol: String {
        switch call.name {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": "pencil"
        case "Grep", "Glob", "WebSearch", "ToolSearch": "magnifyingglass"
        case "WebFetch": "globe"
        case "Agent", "Task": "person.2"
        default: "wrench.and.screwdriver"
        }
    }
}

/// A tool's output: the first lines, with "Show all" for the rest of what's kept.
private struct ToolOutput: View {
    static let previewLines = 12
    let result: ChatToolResult
    @ViewState private var full = false

    var body: some View {
        let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false)
        let long = lines.count > Self.previewLines
        VStack(alignment: .leading, spacing: 4) {
            Text(result.isError ? "Error output" : "Output").font(.caption2).foregroundStyle(.secondary)
            if result.text.isEmpty {
                Text(result.images > 0 ? "\(result.images) image\(result.images == 1 ? "" : "s")" : "Empty")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                CodeBox(code: long && !full ? lines.prefix(Self.previewLines).joined(separator: "\n") : result.text)
            }
            HStack(spacing: 12) {
                if long {
                    Button(full ? "Show less" : "Show all \(lines.count) lines") { full.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
                if result.omitted > 0 {
                    Text("\(result.omitted.formatted()) more characters not kept").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// Thinking, a compaction summary, a command's output — collapsed by default.
struct ChatDetailRow: View {
    let title: String
    let text: String
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        CollapsibleRow(expanded: expanded, toggle: toggle) {
            Image(systemName: title == "Thinking" ? "brain" : "text.alignleft").font(.caption)
            Text(title).font(.callout)
        } content: {
            ChatRichText(text: text).foregroundStyle(.secondary)
        }
    }
}
