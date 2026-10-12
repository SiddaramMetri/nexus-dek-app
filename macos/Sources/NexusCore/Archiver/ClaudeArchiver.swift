import Foundation

/// The Claude chat Archiver's public surface (the Rust `commands::archiver`).
/// EVERY mutation shows a native confirm first — inside NexusCore, so the UI
/// can't bypass it — and is journaled by `ArchiverStore`. All filesystem work
/// runs off the main actor (these are nonisolated async functions).
public enum ClaudeArchiver {
    /// Whether Claude Code exists on this machine (~/.claude/projects present) —
    /// the Claude Chats module hides entirely when it doesn't.
    public static var isInstalled: Bool { ArchiverFS.isDir(Paths.claudeProjects) }

    public static func projects() async throws -> [ClaudeProject] { try ArchiverStore.live.listProjects() }

    public static func sessions(dirName: String) async throws -> [ArchivedChat] {
        try ArchiverStore.live.sessions(dirName)
    }

    public static func archived() async throws -> [ArchivedProject] { try ArchiverStore.live.archived() }

    public static func settings() async throws -> ClaudeSettings { ArchiverStore.live.settings() }

    /// Silent dry-run of the cutoff archive.
    public static func previewArchive(dirName: String, cutoffDays: Int) async throws -> ArchiveResult {
        try ArchiverStore.live.archive(dirName, cutoffDays: cutoffDays, apply: false)
    }

    /// Cutoff archive. Previews first so the confirm can state the real count.
    public static func archive(dirName: String, cutoffDays: Int, confirmer: Confirmer) async throws -> ArchiveResult {
        let store = ArchiverStore.live
        let n = try store.archive(dirName, cutoffDays: cutoffDays, apply: false).candidates.count
        if n > 0 {
            try await confirmer.require(
                title: "Archive \(n) \(chats(n)) older than \(cutoffDays) days?",
                message: archiveMessage, action: "Archive", destructive: false)
        }
        return try store.archive(dirName, cutoffDays: cutoffDays, apply: true)
    }

    /// Archive an explicit selection.
    public static func archiveFiles(dirName: String, files: [String], confirmer: Confirmer) async throws -> BulkResult {
        try await confirmer.require(
            title: "Archive \(files.count) selected \(chats(files.count))?",
            message: archiveMessage, action: "Archive", destructive: false)
        return try ArchiverStore.live.archiveFiles(dirName, files)
    }

    public static func restore(dirName: String, files: [String], confirmer: Confirmer) async throws -> BulkResult {
        try await confirmer.require(
            title: "Restore \(files.count) \(chats(files.count))?",
            message: "They move back into the project — restart VSCode to see them again.",
            action: "Restore", destructive: false)
        return try ArchiverStore.live.restore(dirName, files)
    }

    /// Permanent delete from the archive.
    public static func delete(folder: String, files: [String], confirmer: Confirmer) async throws -> BulkResult {
        try await confirmer.require(
            title: "Delete \(files.count) archived \(chats(files.count))?",
            message: "Permanent — these transcripts cannot be recovered afterwards.",
            action: "Delete", destructive: true)
        return try ArchiverStore.live.delete(folder, files)
    }

    /// Permanent delete of LIVE chats — skips the archive entirely.
    public static func deleteLive(dirName: String, files: [String], confirmer: Confirmer) async throws -> BulkResult {
        try await confirmer.require(
            title: "Delete \(files.count) \(chats(files.count))?",
            message: "Permanent — these transcripts are removed without archiving and cannot be recovered. "
                + "To keep them, archive instead.",
            action: "Delete", destructive: true)
        return try ArchiverStore.live.deleteLive(dirName, files)
    }

    /// Claude Code's `cleanupPeriodDays` (silent transcript deletion).
    public static func setRetention(days: Int, confirmer: Confirmer) async throws {
        try await confirmer.require(
            title: "Keep Claude chats for \(days) days?",
            message: "Claude Code silently deletes transcripts older than this. A backup of settings.json is "
                + "written before the change.",
            action: "Save", destructive: false)
        try ArchiverStore.live.setRetention(days)
    }

    /// Archive-by-age across every project (dry-run first so untouched projects
    /// get no INDEX/journal churn). Returns a notification line, or nil when
    /// nothing moved. Per-project failures are skipped.
    public static func autoArchiveAll(cutoffDays: Int) async -> String? {
        autoArchiveAll(store: .live, cutoffDays: cutoffDays)
    }

    static func autoArchiveAll(store: ArchiverStore, cutoffDays: Int) -> String? {
        guard let dirs = ArchiverFS.entries(store.projectsDir) else { return nil }
        var moved = 0, touched = 0
        for dir in dirs where ArchiverFS.isDir(dir) {
            let name = dir.lastPathComponent
            guard let preview = try? store.archive(name, cutoffDays: cutoffDays, apply: false),
                  !preview.candidates.isEmpty,
                  let res = try? store.archive(name, cutoffDays: cutoffDays, apply: true), res.moved > 0 else { continue }
            moved += res.moved
            touched += 1
        }
        guard moved > 0 else { return nil }
        return "Archived \(moved) old chat\(moved == 1 ? "" : "s") across \(touched) project\(touched == 1 ? "" : "s")"
    }

    /// Epoch secs → "17 Jul 2026" (the Rust `format_date`, UTC).
    public static func formatDate(_ epoch: UInt64) -> String { ArchiverText.formatDate(epoch) }

    /// "just now" · "5h ago" · "yesterday" · "12 days ago" · …
    public static func ago(_ epoch: UInt64) -> String {
        Format.relative(Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    private static let archiveMessage =
        "They move to ~/claude-history-archive — nothing is deleted, and any chat can be restored later."

    private static func chats(_ n: Int) -> String { n == 1 ? "chat" : "chats" }
}
