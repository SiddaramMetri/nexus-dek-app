import Foundation

// VSCode Doctor — orphan workspaceStorage + state.vscdb bloat (the Rust
// `doctor::vscode`). Probes are strictly read-only (SQLite opened READONLY);
// fixes re-scan at fix time and never accept a path from the UI.

struct OrphanScan: Equatable {
    var dirs: [URL]
    var bytes: UInt64
}

enum VSCodeProbes {
    static let orphansId = "vscode_orphans"
    static let dbBloatId = "state_db_bloat"

    static func available() -> Bool { ArchiverFS.isDir(Paths.vscodeUser) }

    // MARK: - Orphan workspaceStorage

    /// workspaceStorage dirs whose plain local project folder no longer exists.
    /// nil when workspaceStorage can't be read.
    static func scanOrphans(root: URL = Paths.vscodeWorkspaceStorage) -> OrphanScan? {
        guard let entries = ArchiverFS.entries(root) else { return nil }
        var scan = OrphanScan(dirs: [], bytes: 0)
        for dir in entries where ArchiverFS.isDir(dir) {
            // No workspace.json → not a plain workspace cache, skip.
            guard let raw = try? String(contentsOf: dir.appendingPathComponent("workspace.json"), encoding: .utf8),
                  let folder = VSCodeCache.folder(fromWorkspaceJSON: raw) else { continue }
            // External volumes may just be unplugged — never treat as orphaned.
            if ArchiverFS.pathStarts(folder, with: "/Volumes") || ArchiverFS.exists(folder) { continue }
            scan.bytes += ArchiverFS.dirSize(dir)
            scan.dirs.append(dir)
        }
        return scan
    }

    static func runOrphans() -> [Finding] {
        guard let scan = scanOrphans() else { return [] }
        return [orphansFinding(scan)]
    }

    static func orphansFinding(_ scan: OrphanScan) -> Finding {
        let n = scan.dirs.count
        if n == 0 {
            return Finding(probeId: orphansId, scope: .vscode, severity: .green, tag: .storage,
                           summary: "No orphan VSCode workspace caches",
                           explain: "Every workspaceStorage entry still has its project folder.")
        }
        return Finding(
            probeId: orphansId, scope: .vscode, severity: .yellow, tag: .storage,
            summary: "\(n) orphan workspace cache\(n == 1 ? "" : "s") · \(fmtMB(scan.bytes))",
            explain: "VSCode keeps a cache folder per workspace it has ever opened. These belong to project folders "
                + "that no longer exist, so nothing can ever use them again (projects on external volumes are "
                + "excluded from this count).",
            fix: "vscode_cleanup_orphans")
    }

    /// Delete orphan workspaceStorage dirs. Re-scans now (never trusts a stale
    /// finding), refuses anything that isn't a direct child of workspaceStorage.
    static func cleanupOrphans(root: URL = Paths.vscodeWorkspaceStorage,
                               journal: ArchiverFS.JournalSink = ArchiverFS.liveJournal) throws -> String {
        guard let scan = scanOrphans(root: root) else { throw AppError.notFound("VSCode not found") }
        var removed = 0, failed = 0
        let rootPath = ArchiverFS.normPath(root.path)
        for dir in scan.dirs {
            if ArchiverFS.normPath(dir.deletingLastPathComponent().path) != rootPath
                || (try? FileManager.default.removeItem(at: dir)) == nil {
                failed += 1
            } else {
                removed += 1
            }
        }
        journal("vscodeCleanupOrphans", ["removed": removed, "failed": failed, "bytes": scan.bytes])
        return "Removed \(removed) orphan cache\(removed == 1 ? "" : "s") · freed \(fmtMB(scan.bytes))"
            + (failed > 0 ? " (\(failed) failed)" : "")
    }

    // MARK: - state.vscdb bloat

    /// Reclaimable bytes worth mentioning / worth alarm.
    static let bloatYellow: UInt64 = 50 * 1024 * 1024
    static let bloatRed: UInt64 = 500 * 1024 * 1024

    static func classifyBloat(_ reclaimable: UInt64) -> Severity? {
        if reclaimable >= bloatRed { return .red }
        if reclaimable >= bloatYellow { return .yellow }
        return nil
    }

    /// Every state.vscdb we know about: each workspace's + the global one.
    static func allStateDBs() -> [URL] {
        var dbs = (ArchiverFS.entries(Paths.vscodeWorkspaceStorage) ?? [])
            .map { $0.appendingPathComponent("state.vscdb") }
            .filter(ArchiverFS.isFile)
        if ArchiverFS.isFile(Paths.vscodeGlobalStateDB) { dbs.append(Paths.vscodeGlobalStateDB) }
        return dbs
    }

    static func runDBBloat() -> [Finding] {
        var total: UInt64 = 0, bloated = 0
        for db in allStateDBs() {
            if let r = VSCodeDB.reclaimable(db), classifyBloat(r) != nil {
                bloated += 1
                total += r
            }
        }
        return [bloatFinding(bloated: bloated, reclaimable: total)]
    }

    static func bloatFinding(bloated: Int, reclaimable: UInt64) -> Finding {
        if bloated == 0 {
            return Finding(probeId: dbBloatId, scope: .vscode, severity: .green, tag: .speed,
                           summary: "VSCode state databases are compact",
                           explain: "No state.vscdb is carrying significant free pages.")
        }
        return Finding(
            probeId: dbBloatId, scope: .vscode, severity: classifyBloat(reclaimable) ?? .yellow, tag: .speed,
            summary: "\(bloated) bloated state.vscdb — \(fmtMB(reclaimable)) reclaimable via VACUUM",
            explain: "SQLite never shrinks a file when rows shrink, and VSCode copies this file on every window "
                + "close — a bloated one makes closing VSCode visibly slow (the original case: 1,057 MB → 19 MB). "
                + "VACUUM rebuilds it compactly; if VSCode is open you'll be asked before it's closed.",
            fix: "vscode_vacuum")
    }

    /// VACUUM every bloated db listed. Callers gate on `stateDBsInUse` first;
    /// SQLite's own locking is the backstop. Also drops VSCode's stale
    /// `state.vscdb.backup` next to each vacuumed db (recreated on next close).
    static func vacuumBloated(_ dbs: [URL], journal: ArchiverFS.JournalSink = ArchiverFS.liveJournal) -> String {
        var lines: [String] = [], freed: UInt64 = 0
        for db in dbs {
            guard let reclaimable = VSCodeDB.reclaimable(db), classifyBloat(reclaimable) != nil else { continue }
            let before = ArchiverFS.size(db) ?? 0
            let name = db.deletingLastPathComponent().lastPathComponent
            if let err = VSCodeDB.vacuum(db) {
                lines.append("\(name): skipped (\(err))")
            } else {
                let after = ArchiverFS.size(db) ?? before
                freed += before > after ? before - after : 0
                try? FileManager.default.removeItem(at: db.appendingPathExtension("backup"))
                lines.append("\(name): \(fmtMB(before)) → \(fmtMB(after))")
            }
        }
        if lines.isEmpty { return "Nothing needed a VACUUM." }
        journal("vscodeVacuum", ["freedBytes": freed, "dbs": lines.count])
        return "Freed \(fmtMB(freed)) — \(lines.joined(separator: "; "))"
    }

    // MARK: - Helpers

    static func fmtMB(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}
