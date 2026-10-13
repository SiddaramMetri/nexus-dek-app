import Foundation

/// Claude Archiver core (the Rust `doctor::claude`). Synchronous filesystem
/// work; `ClaudeArchiver` wraps it with confirms and runs it off the main actor.
///
/// Safety rules:
/// - Move-only — the exceptions are the two deletes, each confirm-gated and
///   journaled like every mutation. A destination that already exists is
///   skipped, never overwritten.
/// - Fail-safe: settings.json not the shape we expect → error out, never guess.
/// - Every mutation is appended to `<archive-root>/journal.jsonl`.
/// - Titles: the user's rename, then VSCode's session cache, then the INDEX
///   row (which preserves good titles after the cache forgets them), then the
///   jsonl's own title lines / first prompt — never blank.
struct ArchiverStore {
    var projectsDir: URL
    var archiveRoot: URL
    var settingsFile: URL
    var home: String
    var workspaceStorage: URL
    var journal: ArchiverFS.JournalSink

    static var live: ArchiverStore {
        ArchiverStore(projectsDir: Paths.claudeProjects, archiveRoot: Paths.archiveRoot,
                      settingsFile: Paths.claudeSettings, home: Paths.home.path,
                      workspaceStorage: Paths.vscodeWorkspaceStorage, journal: ArchiverFS.liveJournal)
    }

    // MARK: - Listing

    func listProjects() throws -> [ClaudeProject] {
        guard let entries = ArchiverFS.entries(projectsDir) else { throw io("no such directory: \(projectsDir.path)") }
        // One workspaceStorage sweep for all projects (the VSCode-cache join).
        let wsMap = VSCodeCache.workspaceFolderMap(root: workspaceStorage)
        var out: [ClaudeProject] = []
        for path in entries where ArchiverFS.isDir(path) {
            let dirName = path.lastPathComponent
            var sessions = 0, bytes: UInt64 = 0, newest: UInt64?
            for f in ArchiverFS.jsonlFiles(path) {
                sessions += 1
                bytes += ArchiverFS.size(f) ?? 0
                if let ep = ArchiverFS.mtimeEpoch(f), ep > (newest ?? 0) || newest == nil { newest = ep }
            }
            let real = ArchiverText.decodeProjectPath(dirName)
            let cacheBytes = real.flatMap { r in
                wsMap.first { $0.folder == ArchiverFS.normPath(r) }.flatMap { VSCodeCache.sessionCache(in: $0.ws)?.bytes }
            }
            out.append(ClaudeProject(
                dirName: dirName,
                displayName: real.flatMap { $0.split(separator: "/").last.map(String.init) }
                    ?? ArchiverText.fallbackDisplay(dirName, home: home),
                realPath: real, sessions: sessions, totalBytes: bytes, newestEpoch: newest, cacheBytes: cacheBytes))
        }
        // Newest activity first; projects with no chats (nil) last.
        return out.sorted { ($0.newestEpoch.map(Int64.init) ?? -1) > ($1.newestEpoch.map(Int64.init) ?? -1) }
    }

    /// Live (un-archived) sessions of a project, newest first.
    func sessions(_ dirName: String) throws -> [ArchivedChat] {
        let dir = try liveDir(dirName)
        // VSCode's own chat titles beat our first-user-message fallback.
        let cache = cacheTitles(dirName)
        return ArchiverFS.jsonlFiles(dir).map { f in
            let epoch = ArchiverFS.mtimeEpoch(f) ?? 0
            return ArchivedChat(file: f.lastPathComponent, epoch: epoch,
                                title: ArchiverText.chatTitle(f, cached: cache[f.deletingPathExtension().lastPathComponent],
                                                              epoch: epoch),
                                bytes: ArchiverFS.size(f) ?? 0)
        }.sorted { $0.epoch > $1.epoch }
    }

    func archived() throws -> [ArchivedProject] {
        guard ArchiverFS.isDir(archiveRoot), let entries = ArchiverFS.entries(archiveRoot) else { return [] }
        // Archive folder → live project dir (the restore target).
        let byFolder = folderMap()
        var out: [ArchivedProject] = []
        for path in entries where ArchiverFS.isDir(path) {
            let folder = path.lastPathComponent
            let titles = ArchiverText.parseIndex(read(path.appendingPathComponent("INDEX.md")))
            var total: UInt64 = 0
            let chats = ArchiverFS.jsonlFiles(path).map { f -> ArchivedChat in
                let bytes = ArchiverFS.size(f) ?? 0, epoch = ArchiverFS.mtimeEpoch(f) ?? 0
                total += bytes
                let name = f.lastPathComponent
                return ArchivedChat(file: name, epoch: epoch,
                                    title: ArchiverText.chatTitle(f, cached: titles[name], epoch: epoch), bytes: bytes)
            }.sorted { $0.epoch > $1.epoch }
            if chats.isEmpty { continue }
            out.append(ArchivedProject(folder: folder, dirName: byFolder[folder], totalBytes: total, chats: chats))
        }
        return out.sorted { $0.folder < $1.folder }
    }

    // MARK: - Archive / restore / delete

    /// Cutoff-based archive. `apply: false` is the dry-run preview.
    func archive(_ dirName: String, cutoffDays: Int, apply: Bool) throws -> ArchiveResult {
        let src = try liveDir(dirName)
        let now = Journal.nowEpoch, cutoff = UInt64(max(0, cutoffDays)) * 86_400
        // mtime captured BEFORE any move (the bug from the original session).
        let candidates = ArchiverFS.jsonlFiles(src)
            .compactMap { f -> (String, UInt64)? in
                guard let ep = ArchiverFS.mtimeEpoch(f), now > ep, now - ep > cutoff else { return nil }
                return (f.lastPathComponent, ep)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        guard apply else { return ArchiveResult(candidates: candidates, moved: 0, skipped: []) }
        let res = try archiveFiles(dirName, candidates)
        return ArchiveResult(candidates: candidates, moved: res.done, skipped: res.skipped)
    }

    /// Move an explicit selection into the archive: move-only, never
    /// overwrites (existing destination = skip), INDEX regen, journaled.
    func archiveFiles(_ dirName: String, _ files: [String]) throws -> BulkResult {
        let srcDir = try liveDir(dirName)
        let folder = ArchiverText.archiveFolderName(dirName)
        let destDir = archiveRoot.appendingPathComponent(folder, isDirectory: true)
        do { try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true) } catch {
            throw AppError.io(error.localizedDescription)
        }
        let res = moveEach(files, from: srcDir, to: destDir)
        try regenerateIndex(destDir, folder: folder, projectDirName: dirName)
        journal("archive", ["project": folder, "moved": res.done, "skipped": res.skipped.count])
        return res
    }

    /// Move files back into the live project. Per-file problems are skips.
    func restore(_ dirName: String, _ files: [String]) throws -> BulkResult {
        try ArchiverText.validateName(dirName)
        let folder = ArchiverText.archiveFolderName(dirName)
        let srcDir = archiveRoot.appendingPathComponent(folder, isDirectory: true)
        let destDir = projectsDir.appendingPathComponent(dirName, isDirectory: true)
        guard ArchiverFS.isDir(destDir) else { throw AppError.notFound("no such project: \(dirName)") }
        let res = moveEach(files, from: srcDir, to: destDir)
        try regenerateIndex(srcDir, folder: folder, projectDirName: dirName)
        journal("restore", ["project": folder, "restored": res.done, "skipped": res.skipped.count])
        return res
    }

    /// PERMANENT delete from the archive. Works on orphan folders too.
    func delete(_ folder: String, _ files: [String]) throws -> BulkResult {
        try ArchiverText.validateName(folder)
        let dir = archiveRoot.appendingPathComponent(folder, isDirectory: true)
        guard ArchiverFS.isDir(dir) else { throw AppError.notFound("no such archive folder: \(folder)") }
        let res = removeEach(files, in: dir)
        // INDEX note names the live project dir if one still maps to this folder.
        let dirName = folderMap()[folder] ?? folder
        try regenerateIndex(dir, folder: folder, projectDirName: dirName)
        journal("delete", ["project": folder, "deleted": res.done, "skipped": res.skipped.count])
        return res
    }

    /// PERMANENT delete of LIVE chats straight from `~/.claude/projects/<dir>/`.
    func deleteLive(_ dirName: String, _ files: [String]) throws -> BulkResult {
        let dir = try liveDir(dirName)
        let res = removeEach(files, in: dir)
        journal("deleteLive", ["project": dirName, "deleted": res.done, "skipped": res.skipped.count])
        return res
    }

    // MARK: - Retention (settings.json)

    func settings() -> ClaudeSettings {
        ClaudeSettings(cleanupPeriodDays: ArchiverText.retentionDays(read(settingsFile)),
                       archiveRoot: archiveRoot.path)
    }

    func setRetention(_ days: Int) throws {
        guard days >= 0 else { throw AppError.invalidName("bad retention: \(days)") }
        let raw: String
        do { raw = try String(contentsOf: settingsFile, encoding: .utf8) } catch {
            throw AppError.io(error.localizedDescription)
        }
        let updated = try ArchiverText.withRetention(raw, days: days)
        // Backup before editing a file we don't own (kept forever, tiny).
        let bak = settingsFile.deletingPathExtension().appendingPathExtension("json.bak")
        do {
            try? FileManager.default.removeItem(at: bak)
            try FileManager.default.copyItem(at: settingsFile, to: bak)
            try Data(updated.utf8).write(to: settingsFile)
        } catch {
            throw AppError.io(error.localizedDescription)
        }
        journal("setRetention", ["days": days])
    }

    // MARK: - INDEX.md

    /// Rebuild INDEX.md from the archive dir (source of truth, idempotent).
    /// Title priority: VSCode's live cache label → the existing INDEX row →
    /// our jsonl head scan.
    func regenerateIndex(_ dir: URL, folder: String, projectDirName: String) throws {
        let indexURL = dir.appendingPathComponent("INDEX.md")
        let existing = ArchiverText.parseIndex(read(indexURL))
        let cache = cacheTitles(projectDirName)
        let rows: [ArchiverText.IndexRow] = ArchiverFS.jsonlFiles(dir).map { f in
            let name = f.lastPathComponent, epoch = ArchiverFS.mtimeEpoch(f) ?? 0
            let title = ArchiverText.chatTitle(f, cached: cache[f.deletingPathExtension().lastPathComponent] ?? existing[name],
                                               epoch: epoch)
            return (epoch, title, name)
        }.sorted { $0.epoch > $1.epoch }
        let md = ArchiverText.renderIndex(folder: folder, projectDirName: projectDirName, rows: rows)
        do { try Data(md.utf8).write(to: indexURL) } catch { throw AppError.io(error.localizedDescription) }
    }

    // MARK: - Helpers

    private func liveDir(_ dirName: String) throws -> URL {
        try ArchiverText.validateName(dirName)
        let dir = projectsDir.appendingPathComponent(dirName, isDirectory: true)
        guard ArchiverFS.isDir(dir) else { throw AppError.notFound("no such project: \(dirName)") }
        return dir
    }

    private func moveEach(_ files: [String], from src: URL, to dest: URL) -> BulkResult {
        var done = 0, skipped: [String] = []
        for file in files {
            let s = src.appendingPathComponent(file), d = dest.appendingPathComponent(file)
            // rename(2) directly: atomic, same-volume only — like Rust's fs::rename.
            if (try? ArchiverText.validateJsonl(file)) == nil || !ArchiverFS.isFile(s)
                || ArchiverFS.exists(d.path) || Darwin.rename(s.path, d.path) != 0 {
                skipped.append(file)
            } else {
                done += 1
            }
        }
        return BulkResult(done: done, skipped: skipped)
    }

    private func removeEach(_ files: [String], in dir: URL) -> BulkResult {
        var done = 0, skipped: [String] = []
        for file in files {
            // unlink(2): files only, like Rust's fs::remove_file.
            if (try? ArchiverText.validateJsonl(file)) == nil || unlink(dir.appendingPathComponent(file).path) != 0 {
                skipped.append(file)
            } else {
                done += 1
            }
        }
        return BulkResult(done: done, skipped: skipped)
    }

    /// Archive folder name → live project dir name, for every live project.
    private func folderMap() -> [String: String] {
        let dirs = (ArchiverFS.entries(projectsDir) ?? []).filter(ArchiverFS.isDir)
        return Dictionary(dirs.map { (ArchiverText.archiveFolderName($0.lastPathComponent), $0.lastPathComponent) },
                          uniquingKeysWith: { _, last in last })
    }

    private func cacheTitles(_ dirName: String) -> [String: String] {
        ArchiverText.decodeProjectPath(dirName)
            .flatMap { VSCodeCache.sessionCache(forFolder: $0, root: workspaceStorage)?.titles } ?? [:]
    }

    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    private func io(_ message: String) -> AppError { .io(message) }
}
