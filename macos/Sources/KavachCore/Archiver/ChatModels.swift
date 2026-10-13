import Foundation

// Read-only view models of one Claude Code transcript (`<uuid>.jsonl`), as the
// Claude Chats tab renders it: bubbles, compact tool rows, notices. Nothing
// here ever writes to a transcript.

/// Where a transcript lives: a live project dir under `~/.claude/projects`, or
/// an archive folder under `~/claude-history-archive`.
public enum ChatLocation: Hashable, Sendable {
    case live(dirName: String)
    case archived(folder: String)
}

public enum ChatRole: String, Equatable, Sendable {
    case user, assistant
    /// Not a message: a slash command, a compaction, a background-task or
    /// cross-session note. Rendered as a muted centered row.
    case notice
}

/// One tool invocation, reduced to what a row needs ("Bash · `npm test`").
public struct ChatToolCall: Equatable, Sendable {
    public var id: String
    public var name: String
    /// The one-line gist: a command, a file path, a URL, a query…
    public var summary: String
    /// The full input as readable `key: value` lines, capped.
    public var input: String
}

/// A tool's output, capped so a 2 MB result never sits in memory.
public struct ChatToolResult: Equatable, Sendable {
    public var text: String
    public var isError: Bool
    /// Characters dropped by the cap (0 = complete).
    public var omitted: Int
    public var images: Int
}

public enum ChatBlock: Equatable, Sendable {
    case text(String)
    case tool(ChatToolCall)
    /// Collapsed by default: thinking, a compaction summary, a command's output.
    case detail(title: String, body: String)
    case image(count: Int)
}

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public var id: String
    public var role: ChatRole
    public var blocks: [ChatBlock]
    public var timestamp: Date?

    public init(id: String, role: ChatRole, blocks: [ChatBlock], timestamp: Date?) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.timestamp = timestamp
    }

    /// Plain text of the message, for in-conversation search.
    public var searchText: String {
        blocks.map { b in
            switch b {
            case let .text(t): t
            case let .tool(c): c.name + " " + c.summary
            case let .detail(title, body): title + " " + body
            case .image: ""
            }
        }.joined(separator: "\n")
    }
}

/// A run of text split for rendering: prose (inline markdown) or a fenced code block.
public enum ChatSegment: Equatable, Sendable {
    case prose(String)
    case code(language: String, code: String)
}

/// One page of a transcript read backwards from the end.
public struct TranscriptPage: Sendable {
    /// Chronological.
    public var messages: [ChatMessage]
    /// Tool results by `tool_use_id`. Results can land on a later page than
    /// their call, so callers merge these maps across pages.
    public var results: [String: ChatToolResult]
    /// Byte offset of the earliest line read: pass it as `before` to load the
    /// previous page. 0 = the start of the file was reached.
    public var startOffset: UInt64
}

/// Whole-file numbers for a chat list row and the conversation header.
public struct ChatStats: Equatable, Sendable {
    /// Real user prompts + Claude replies that contain text.
    public var messages: Int
    public var firstActivity: Date?
    public var lastActivity: Date?
}
