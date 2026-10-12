import Foundation
import SQLite3

/// Minimal SQLite C-API wrapper for the VSCode state databases — exactly the
/// three things rusqlite did: read-only PRAGMA reads, one ItemTable lookup,
/// and VACUUM.
final class VSCodeDB {
    private let handle: OpaquePointer

    /// Read-only opens never create a file. `busyMs` mirrors rusqlite's default
    /// 5 s busy timeout for reads; VACUUM passes 0 (SQLITE_BUSY is its backstop).
    init?(_ path: String, readOnly: Bool, busyMs: Int32 = 5000) {
        var db: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            if let db { sqlite3_close_v2(db) }
            return nil
        }
        handle = db
        sqlite3_busy_timeout(db, busyMs)
    }

    deinit { sqlite3_close_v2(handle) }

    var lastError: String { String(cString: sqlite3_errmsg(handle)) }

    /// Run one statement to completion; the SQLite message on failure.
    func execute(_ sql: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return lastError }
        defer { sqlite3_finalize(stmt) }
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
        return rc == SQLITE_DONE ? nil : lastError
    }

    /// First column of the first row as an integer (PRAGMA reads).
    func int64(_ sql: String) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) == SQLITE_INTEGER else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    /// One ItemTable value, TEXT or BLOB (lossy UTF-8).
    func item(_ key: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT value FROM ItemTable WHERE key = ?1", -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        switch sqlite3_column_type(stmt, 0) {
        case SQLITE_TEXT, SQLITE_BLOB:
            let n = Int(sqlite3_column_bytes(stmt, 0))
            guard n > 0, let p = sqlite3_column_blob(stmt, 0) else { return "" }
            return String(decoding: UnsafeRawBufferPointer(start: p, count: n), as: UTF8.self)
        default:
            return nil
        }
    }

    // MARK: - VSCode-specific

    /// Free-page bytes a VACUUM would reclaim. nil = unreadable or not a SQLite
    /// db (fail-safe: skip, never guess).
    static func reclaimable(_ db: URL) -> UInt64? {
        guard let conn = VSCodeDB(db.path, readOnly: true),
              let pageSize = conn.int64("PRAGMA page_size"), pageSize >= 0,
              let free = conn.int64("PRAGMA freelist_count"), free >= 0 else { return nil }
        return UInt64(free) * UInt64(pageSize)
    }

    /// VACUUM in place — atomic and content-preserving. The SQLite message on failure.
    static func vacuum(_ db: URL) -> String? {
        guard let conn = VSCodeDB(db.path, readOnly: false, busyMs: 0) else { return "unable to open database file" }
        return conn.execute("VACUUM")
    }
}

/// VSCode's per-workspace Claude session cache: session-uuid → chat title,
/// plus the bytes the cache row itself occupies (the state.vscdb bloat driver).
struct SessionCache: Equatable {
    var titles: [String: String]
    var bytes: UInt64
}

/// The workspaceStorage ↔ Claude project join. Strictly read-only.
enum VSCodeCache {
    /// The ItemTable key VSCode stores the cache under. Undocumented internal —
    /// guarded by `parseSessionCache`'s fail-safe.
    static let sessionCacheKey = "agentSessions.model.cache"

    /// workspace.json → the folder this cache belongs to. Only plain local
    /// `file://` single-folder workspaces qualify — multi-root and remote
    /// entries are skipped (can't cheaply verify → never flag).
    static func folder(fromWorkspaceJSON raw: String) -> String? {
        guard let v = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let uri = v["folder"] as? String, uri.hasPrefix("file://") else { return nil }
        return percentDecode(String(uri.dropFirst("file://".count)))
    }

    /// Just enough percent-decoding for file:// URIs (%20 etc.).
    static func percentDecode(_ s: String) -> String {
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count,
               let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
                continue
            }
            out.append(bytes[i])
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): b - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): b - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): b - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    /// Every workspaceStorage dir ↔ the (normalized) local folder it belongs to.
    static func workspaceFolderMap(root: URL = Paths.vscodeWorkspaceStorage) -> [(ws: URL, folder: String)] {
        (ArchiverFS.entries(root) ?? []).compactMap { dir in
            guard let raw = try? String(contentsOf: dir.appendingPathComponent("workspace.json"), encoding: .utf8),
                  let folder = folder(fromWorkspaceJSON: raw) else { return nil }
            return (dir, ArchiverFS.normPath(folder))
        }
    }

    /// Titles for the workspace that has `folder` open — nil when VSCode never
    /// opened it, has no cache row, or the row's shape is unrecognized.
    static func sessionCache(forFolder folder: String, root: URL = Paths.vscodeWorkspaceStorage) -> SessionCache? {
        let target = ArchiverFS.normPath(folder)
        guard let ws = workspaceFolderMap(root: root).first(where: { $0.folder == target }) else { return nil }
        return sessionCache(in: ws.ws)
    }

    static func sessionCache(in wsDir: URL) -> SessionCache? {
        let db = wsDir.appendingPathComponent("state.vscdb")
        guard let raw = VSCodeDB(db.path, readOnly: true)?.item(sessionCacheKey) else { return nil }
        return parseSessionCache(raw)
    }

    /// Contract: a JSON array of entries with `resource: "claude-code:/<uuid>"`
    /// and `label`. Malformed ENTRIES are skipped; a malformed TOP LEVEL is nil.
    static func parseSessionCache(_ raw: String) -> SessionCache? {
        guard let arr = (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])) as? [Any]
        else { return nil }
        var titles: [String: String] = [:]
        for case let item as [String: Any] in arr {
            guard let resource = item["resource"] as? String, let label = item["label"] as? String else { continue }
            let uuid = resource.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            if !uuid.isEmpty { titles[uuid] = label }
        }
        return SessionCache(titles: titles, bytes: UInt64(raw.utf8.count))
    }
}
