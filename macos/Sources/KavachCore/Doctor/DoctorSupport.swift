import Foundation

/// Small shared helpers for the Doctor probes (`deepscan::du_bytes`, mtime,
/// JSON) plus delegates to the formatters other ports own.
enum DoctorSupport {
    static var nowEpoch: UInt64 { Journal.nowEpoch }

    // The Rust shared formatters live with their owning ports; delegate so
    // there is one implementation of each.
    static func mb(_ bytes: UInt64) -> String { VSCodeDoctor.fmtMB(bytes) }
    static func ago(_ epoch: UInt64) -> String { ClaudeArchiver.ago(epoch) }
    static func formatDate(_ epoch: UInt64) -> String { ClaudeArchiver.formatDate(epoch) }

    static func mtimeEpoch(_ url: URL) -> UInt64? {
        guard let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              d.timeIntervalSince1970 >= 0 else { return nil }
        return UInt64(d.timeIntervalSince1970)
    }

    static func isDir(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    static func isFile(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && !dir.boolValue
    }

    /// Directory children (hidden files included, like `read_dir`); empty when unreadable.
    static func children(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    }

    // MARK: - du

    /// "487344\t/Users/x/node_modules" → 487344
    static func parseDuKB(_ s: String) -> UInt64? {
        s.split(whereSeparator: \.isWhitespace).first.flatMap { UInt64($0) }
    }

    /// `du -sk` (fast C walk). 0 when unmeasurable. Cancelling the calling task
    /// terminates the `du`, so a deep-scan cancel lands within one measurement.
    static func duBytes(_ url: URL) async -> UInt64 {
        let out = await Proc.anyOutput("du", ["-sk", url.path])
        return (parseDuKB(out) ?? 0) * 1024
    }

    // MARK: - JSON

    static func jsonObject(_ raw: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
    }

    /// A real JSON boolean — never a number that happens to bridge to Bool.
    static func jsonBool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    /// A non-negative JSON integer (serde `as_u64`).
    static func jsonUInt(_ value: Any?) -> UInt64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d >= 0, d == d.rounded(.towardZero) else { return nil }
        return n.uint64Value
    }

    /// Component-wise `Path::starts_with`.
    static func path(_ url: URL, isInside root: URL) -> Bool {
        let p = url.standardizedFileURL.path, r = root.standardizedFileURL.path
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }
}
