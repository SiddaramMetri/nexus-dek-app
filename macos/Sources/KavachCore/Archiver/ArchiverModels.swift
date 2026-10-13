import Foundation

// DTOs — field-for-field the Rust `doctor::claude` structs.

public struct ClaudeProject: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { dirName }
    public var dirName: String
    public var displayName: String
    public var realPath: String?
    public var sessions: Int
    public var totalBytes: UInt64
    public var newestEpoch: UInt64?
    /// Measured size of VSCode's session-cache row for this workspace — nil
    /// when VSCode has no (recognizable) cache for it.
    public var cacheBytes: UInt64?
}

public struct ArchiveResult: Equatable, Sendable {
    public var candidates: [String]
    public var moved: Int
    public var skipped: [String]
}

public struct BulkResult: Equatable, Sendable {
    public var done: Int
    public var skipped: [String]
}

/// One chat transcript — live or archived (both sections render identically).
public struct ArchivedChat: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { file }
    public var file: String
    public var epoch: UInt64
    public var title: String
    /// Transcript size on disk.
    public var bytes: UInt64

    public init(file: String, epoch: UInt64, title: String, bytes: UInt64 = 0) {
        self.file = file
        self.epoch = epoch
        self.title = title
        self.bytes = bytes
    }
}

public struct ArchivedProject: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { folder }
    public var folder: String
    /// Live project dir this folder maps back to — nil means restore target unknown.
    public var dirName: String?
    public var totalBytes: UInt64
    public var chats: [ArchivedChat]
}

public struct ClaudeSettings: Equatable, Sendable {
    public var cleanupPeriodDays: Int?
    public var archiveRoot: String
}

/// One row of the Archiver's master list: a live project, an orphan archive
/// folder (original project removed), or both sides of one project.
public struct ArchiverRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var subtitle: String
    public var live: ClaudeProject?
    public var archived: ArchivedProject?

    /// Live projects first (already newest-activity-first), then orphan archive
    /// folders. Rows with 0 live AND 0 archived chats are noise, not projects.
    public static func build(projects: [ClaudeProject], archived: [ArchivedProject]) -> [ArchiverRow] {
        let live = projects.map { p in
            ArchiverRow(id: p.dirName, displayName: p.displayName,
                        subtitle: p.realPath ?? "original folder not found",
                        live: p, archived: archived.first { $0.dirName == p.dirName })
        }
        let orphans = archived.filter { $0.dirName == nil }.map { a in
            ArchiverRow(id: "orphan:\(a.folder)", displayName: a.folder,
                        subtitle: "archive only — original project removed", live: nil, archived: a)
        }
        return (live + orphans).filter { ($0.live?.sessions ?? 0) + ($0.archived?.chats.count ?? 0) > 0 }
    }
}

extension ArchivedChat {
    /// Live-list age filter: chats strictly older than `days`. `days <= 0`
    /// (the "All" filter) keeps everything.
    public static func olderThan(_ chats: [ArchivedChat], days: Int, now: UInt64) -> [ArchivedChat] {
        guard days > 0 else { return chats }
        let cutoff = UInt64(days) * 86_400
        return chats.filter { now > $0.epoch && now - $0.epoch > cutoff }
    }
}
