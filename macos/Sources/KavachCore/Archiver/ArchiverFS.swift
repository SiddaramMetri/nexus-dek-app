import Darwin
import Foundation

/// Small filesystem helpers shared by the Archiver and the VSCode doctor.
/// `stat` (not `lstat`) on purpose: like Rust's `Path::is_dir`/`metadata`,
/// symlinks are followed.
enum ArchiverFS {
    /// Where a mutation's journal line goes. Tests pass a capturing sink so they
    /// never touch the real `~/claude-history-archive/journal.jsonl`.
    typealias JournalSink = (_ action: String, _ fields: [String: Any]) -> Void

    static let liveJournal: JournalSink = { action, fields in Journal.write(action: action, fields) }

    static func info(_ path: String) -> Darwin.stat? {
        var st = Darwin.stat()
        return stat(path, &st) == 0 ? st : nil
    }

    static func isDir(_ url: URL) -> Bool { info(url.path).map { $0.st_mode & S_IFMT == S_IFDIR } ?? false }
    static func isFile(_ url: URL) -> Bool { info(url.path).map { $0.st_mode & S_IFMT == S_IFREG } ?? false }
    static func exists(_ path: String) -> Bool { info(path) != nil }
    static func size(_ url: URL) -> UInt64? { info(url.path).map { UInt64(max(0, $0.st_size)) } }

    /// Whole seconds since the epoch; nil for pre-1970 or unreadable entries.
    static func mtimeEpoch(_ url: URL) -> UInt64? {
        guard let st = info(url.path), st.st_mtimespec.tv_sec >= 0 else { return nil }
        return UInt64(st.st_mtimespec.tv_sec)
    }

    /// Direct children (hidden ones included), or nil when the dir can't be read.
    static func entries(_ dir: URL) -> [URL]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        return names.map { dir.appendingPathComponent($0) }
    }

    static func jsonlFiles(_ dir: URL) -> [URL] {
        (entries(dir) ?? []).filter { $0.pathExtension == "jsonl" && isFile($0) }
    }

    /// First 64 KB, lossily decoded — enough for a title scan of huge transcripts.
    static func readHead(_ url: URL, bytes: Int = 64 * 1024) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: bytes)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Last 128 KB, lossily decoded — where Claude Code appends title lines.
    static func readTail(_ url: URL, bytes: UInt64 = 128 * 1024) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        guard size > UInt64(64 * 1024) else { return "" } // the head read already covered it
        try? h.seek(toOffset: size > bytes ? size - bytes : 0)
        return String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
    }

    static func dirSize(_ dir: URL) -> UInt64 {
        (entries(dir) ?? []).reduce(0) { sum, p in sum + (isDir(p) ? dirSize(p) : size(p) ?? 0) }
    }

    /// Component-wise path normalization (what `PathBuf ==` compares): no
    /// duplicate or trailing slashes, no `.` segments.
    static func normPath(_ path: String) -> String {
        let parts = path.split(separator: "/").filter { $0 != "." }
        return (path.hasPrefix("/") ? "/" : "") + parts.joined(separator: "/")
    }

    /// `path` is `prefix` or lives under it (component-wise, like `Path::starts_with`).
    static func pathStarts(_ path: String, with prefix: String) -> Bool {
        let p = normPath(path), pre = normPath(prefix)
        return p == pre || p.hasPrefix(pre == "/" ? "/" : pre + "/")
    }
}
