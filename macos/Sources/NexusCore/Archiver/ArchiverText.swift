import Foundation

/// Pure helpers of the Archiver: titles, INDEX.md, dates, path encoding,
/// name validation and the settings.json edit. No side effects except the
/// read-only directory walk in `decodeProjectPath`.
enum ArchiverText {
    // MARK: - Titles

    /// Best-effort chat title from the head of a session .jsonl: a `summary`
    /// line wins, else the first real user message, truncated.
    static func sessionTitle(_ head: String) -> String? {
        var userMsg: String?
        for line in lines(head).prefix(40) {
            guard let v = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            switch v["type"] as? String {
            case "summary":
                if let s = v["summary"] as? String { return truncate(s, 60) }
            case "user" where userMsg == nil:
                let content = (v["message"] as? [String: Any])?["content"]
                var text: String?
                if let s = content as? String {
                    text = s
                } else if let a = content as? [Any] {
                    text = a.lazy.compactMap { ($0 as? [String: Any])?["text"] as? String }.first
                }
                if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<") {
                    userMsg = truncate(t, 60)
                }
            default:
                break
            }
        }
        return userMsg
    }

    /// Rust `str::lines`: split on `\n`, drop a trailing `\r`, no final empty line.
    static func lines(_ s: String) -> [Substring] {
        var out = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
        if s.hasSuffix("\n") { out.removeLast() }
        return out
    }

    /// Collapse whitespace; cut to `max` scalars with an ellipsis.
    static func truncate(_ s: String, _ max: Int) -> String {
        let clean = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let scalars = clean.unicodeScalars
        guard scalars.count > max else { return clean }
        var cut = String(String.UnicodeScalarView(scalars.prefix(max - 1)))
        while cut.last?.isWhitespace == true { cut.removeLast() }
        return cut + "…"
    }

    // MARK: - INDEX.md

    typealias IndexRow = (epoch: UInt64, title: String, file: String)

    static func renderIndex(folder: String, projectDirName: String, rows: [IndexRow]) -> String {
        var s = "# Claude chat archive — \(folder)\n\nTo restore: move the file back to\n"
            + "`~/.claude/projects/\(projectDirName)/` and restart VSCode.\n\n"
            + "| Date | Chat | File |\n|---|---|---|\n"
        for r in rows { s += "| \(formatDate(r.epoch)) | \(r.title) | \(r.file) |\n" }
        return s
    }

    /// file → title map from an existing INDEX.md table (tolerant of anything).
    static func parseIndex(_ md: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in lines(md) {
            // "| date | title | file |" splits into ["", date, title, file, ""]
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.count == 5, cells[3].hasSuffix(".jsonl") { out[cells[3]] = cells[2] }
        }
        return out
    }

    // MARK: - Dates

    /// Epoch secs → "15 Jul 2026" (Howard Hinnant's civil_from_days, UTC).
    static func formatDate(_ epoch: UInt64) -> String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let z = Int64(epoch / 86_400) + 719_468
        let era = z >= 0 ? z / 146_097 : (z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return "\(d) \(months[Int(m) - 1]) \(y)"
    }

    // MARK: - Project path decode

    /// Claude's encoding maps EVERY non-alphanumeric char to '-' (spaces, dots,
    /// underscores — "VSS Batches" → "VSS-Batches", "Draw.io" → "Draw-io").
    static func encodeSegment(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.map { s in
            s.isASCII && (s.properties.isAlphabetic || ("0"..."9").contains(s)) ? s : "-"
        }))
    }

    /// `~/.claude/projects` dir names are the project path with `/` and `.`
    /// flattened to `-` — ambiguous with real dashes ("9-June"). Decode by
    /// walking the filesystem: at each level, the longest existing entry whose
    /// encoded form prefixes the remainder wins.
    static func decodeProjectPath(_ dirName: String, root: String = "/") -> String? {
        guard dirName.hasPrefix("-") else { return nil }
        return walkDecode(base: root, rest: String(dirName.dropFirst()))
    }

    static func walkDecode(base: String, rest: String) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        for name in names.sorted(by: { $0.utf8.count > $1.utf8.count }) { // longest match first
            let enc = encodeSegment(name)
            let path = base == "/" ? "/" + name : base + "/" + name
            if rest == enc { return path }
            if rest.hasPrefix(enc + "-"), let found = walkDecode(base: path, rest: String(rest.dropFirst(enc.count + 1))) {
                return found
            }
        }
        return nil
    }

    /// Display fallback when the original folder no longer exists: drop the
    /// encoded home prefix so "-Users-x-Documents-Foo-Bar" reads "Documents-Foo-Bar".
    static func fallbackDisplay(_ dirName: String, home: String) -> String {
        let raw = String(dirName.drop { $0 == "-" })
        let homeEnc = encodeSegment(String(home.drop { $0 == "/" }))
        return raw.hasPrefix(homeEnc + "-") ? String(raw.dropFirst(homeEnc.count + 1)) : raw
    }

    /// Archive folder = last real path segment ("9-June", matching the live archive).
    // Two projects with the same basename share a folder — files are uuid-named,
    // so nothing collides destructively.
    static func archiveFolderName(_ dirName: String) -> String {
        if let real = decodeProjectPath(dirName), let last = real.split(separator: "/").last { return String(last) }
        return String(dirName.drop { $0 == "-" })
    }

    // MARK: - Validation

    static func validateName(_ dirName: String) throws {
        if dirName.isEmpty || dirName.contains("/") || dirName.contains("..") {
            throw AppError.invalidName("bad project dir: \(dirName)")
        }
    }

    static func validateJsonl(_ file: String) throws {
        if file.contains("/") || file.contains("..") || !file.hasSuffix(".jsonl") {
            throw AppError.invalidName("bad session file: \(file)")
        }
    }

    // MARK: - settings.json

    /// Parse-modify-write, preserving every other key. Fail-safe: anything other
    /// than a JSON object at the top level is "unrecognized" → refuse.
    static func withRetention(_ raw: String, days: Int) throws -> String {
        let v: Any
        do {
            v = try JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed])
        } catch {
            throw AppError.parse("settings.json: \(error.localizedDescription)")
        }
        guard var obj = v as? [String: Any] else { throw AppError.parse("settings.json: unrecognized shape") }
        obj["cleanupPeriodDays"] = days
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// `cleanupPeriodDays` only when it's an integer (serde's `as_i64`).
    static func retentionDays(_ raw: String) -> Int? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let n = obj["cleanupPeriodDays"] as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n) else { return nil }
        return n.intValue
    }
}
