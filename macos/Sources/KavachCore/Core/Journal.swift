import Foundation

/// Append-only mutation audit trail at `<archive-root>/journal.jsonl`. Shared by
/// every Doctor/Archiver/VSCode mutation.
public enum Journal {
    public struct Entry: Equatable, Sendable, Identifiable {
        public var id: String { "\(tsEpoch)-\(action)-\(detail)" }
        public var tsEpoch: UInt64
        public var action: String
        public var detail: String
    }

    static var file: URL { Paths.archiveRoot.appendingPathComponent("journal.jsonl") }

    public static var nowEpoch: UInt64 { UInt64(Date().timeIntervalSince1970) }

    /// Best-effort by design: a failed write must never block the mutation it
    /// records (the mutation already happened). `fields` are merged after
    /// `tsEpoch` and `action`.
    public static func write(action: String, _ fields: [String: Any] = [:]) {
        var obj: [String: Any] = ["tsEpoch": nowEpoch, "action": action]
        obj.merge(fields) { a, _ in a }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        writeLine(String(decoding: data, as: UTF8.self))
    }

    /// Append one pre-rendered JSON line.
    public static func writeLine(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.archiveRoot, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: file) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data((line + "\n").utf8))
    }

    /// Newest first; unparseable lines are skipped.
    public static func read(limit: Int) -> [Entry] {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return Array(raw.split(whereSeparator: \.isNewline).compactMap { parse(String($0)) }.reversed().prefix(limit))
    }

    static func parse(_ line: String) -> Entry? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let ts = (obj["tsEpoch"] as? NSNumber)?.uint64Value,
              let action = obj["action"] as? String else { return nil }
        let detail = obj.filter { $0.key != "tsEpoch" && $0.key != "action" }
            .sorted { $0.key < $1.key }
            .map { k, v in "\(k) \(v as? String ?? String(describing: v))" }
            .joined(separator: " · ")
        return Entry(tsEpoch: ts, action: action, detail: detail)
    }
}
