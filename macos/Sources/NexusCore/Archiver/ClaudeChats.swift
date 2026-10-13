import Foundation

/// Reading Claude chats and continuing them. Everything here is read-only;
/// the mutations stay in `ClaudeArchiver` behind its confirms. File work runs
/// off the main actor (nonisolated async functions).
public enum ClaudeChats {
    /// Messages per page: the latest page first, then "Load earlier".
    public static let pageSize = 200

    public static func page(_ location: ChatLocation, file: String, before: UInt64? = nil,
                            limit: Int = pageSize) async throws -> TranscriptPage {
        try ChatReader.page(url(location, file: file), before: before, limit: limit)
    }

    /// Whole-file numbers. `queued` (list rows) waits its turn behind other
    /// row scans; the open chat passes false to scan immediately.
    public static func stats(_ location: ChatLocation, file: String, queued: Bool = true) async throws -> ChatStats {
        let url = try url(location, file: file)
        return queued ? try await ChatStatsCache.shared.queued(url) : try await ChatStatsCache.shared.now(url)
    }

    /// Prose / fenced-code split of a message text, for rendering.
    public static func segments(_ text: String) -> [ChatSegment] { ChatText.segments(text) }

    // MARK: - Continue in Claude Code

    /// The session id is the file name — accepted only as a canonical UUID,
    /// since it ends up typed into a shell.
    public static func sessionID(file: String) -> String? {
        guard file.hasSuffix(".jsonl") else { return nil }
        let id = String(file.dropLast(6))
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        guard id.utf8.count == 36, id.unicodeScalars.allSatisfy(hex.contains), UUID(uuidString: id) != nil,
              id.split(separator: "-", omittingEmptySubsequences: false).map(\.count) == [8, 4, 4, 4, 12] else { return nil }
        return id
    }

    public static func resumeCommand(file: String) throws -> String {
        guard let id = sessionID(file: file) else { throw AppError.invalidName("not a session id: \(file)") }
        return "claude --resume \(id)"
    }

    public static let newChatCommand = "claude"

    /// Why a chat can't be continued in `folder` (nil = it can): an absolute
    /// path with no `..` segments that exists as a folder strictly inside the
    /// home folder, before and after resolving symlinks.
    public static func launchProblem(folder: String?, home: String = Paths.home.path) -> String? {
        let gone = "The project folder no longer exists"
        let outside = "Only folders inside your home folder can be opened in the terminal"
        guard let folder else { return gone }
        guard folder.hasPrefix("/"), !folder.split(separator: "/").contains("..") else { return outside }
        guard ArchiverFS.isDir(URL(fileURLWithPath: folder)) else { return gone }
        let resolved = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        let realHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        for (path, root) in [(folder, home), (resolved, realHome)] {
            let norm = ArchiverFS.normPath(path)
            guard norm != ArchiverFS.normPath(root), ArchiverFS.pathStarts(norm, with: root) else { return outside }
        }
        return nil
    }

    /// Why a chat can't be resumed at all (nil = it can): Claude Code only finds
    /// sessions under `~/.claude/projects`, so archived chats need a restore first.
    public static func resumeProblem(_ location: ChatLocation, file: String) -> String? {
        guard sessionID(file: file) != nil else { return "This chat has no valid session id" }
        if case .archived = location { return "Restore this chat to continue it in Claude Code" }
        return nil
    }

    /// `cd '<folder>' && claude --resume <id>`, safe to paste into any shell.
    public static func copyableResumeCommand(file: String, folder: String) throws -> String {
        "cd \(shellQuote(folder)) && " + (try resumeCommand(file: file))
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    // MARK: - Paths

    static func url(_ location: ChatLocation, file: String, store: ArchiverStore = .live) throws -> URL {
        try ArchiverText.validateJsonl(file)
        let dir: URL
        switch location {
        case let .live(dirName):
            try ArchiverText.validateName(dirName)
            dir = store.projectsDir.appendingPathComponent(dirName, isDirectory: true)
        case let .archived(folder):
            try ArchiverText.validateName(folder)
            dir = store.archiveRoot.appendingPathComponent(folder, isDirectory: true)
        }
        let url = dir.appendingPathComponent(file)
        guard ArchiverFS.isFile(url) else { throw AppError.notFound("chat not found: \(file)") }
        return url
    }
}
