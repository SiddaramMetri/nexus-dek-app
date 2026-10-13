import Foundation

/// Streaming, read-only access to transcript files. Some are 50–150 MB, so a
/// page is read backwards from a byte offset in 1 MB chunks and only the lines
/// that page needs are decoded; whole-file stats stream forwards the same way.
enum ChatReader {
    static let chunk = 1 << 20

    /// Each complete line before `end`, newest first, with its start offset.
    /// `body` returns false to stop.
    static func linesBackward(_ url: URL, end: UInt64? = nil,
                              _ body: (UnsafeRawBufferPointer, UInt64) -> Bool) throws {
        let h = try open(url)
        defer { try? h.close() }
        var end = min(end ?? UInt64.max, (try? h.seekToEnd()) ?? 0)
        // Head of a line whose start lies before `end` (no newline seen yet).
        var carry = Data()
        while end > 0 {
            let start = end > UInt64(chunk) ? end - UInt64(chunk) : 0
            try h.seek(toOffset: start)
            var buf = (try h.read(upToCount: Int(end - start))) ?? Data()
            buf.append(carry)
            let keepGoing = buf.withUnsafeBytes { raw -> Bool in
                var segEnd = raw.count
                for i in newlines(raw).reversed() {
                    let line = UnsafeRawBufferPointer(rebasing: raw[(i + 1)..<segEnd])
                    if !line.isEmpty, !body(line, start + UInt64(i + 1)) { return false }
                    segEnd = i
                }
                if start == 0 {
                    let line = UnsafeRawBufferPointer(rebasing: raw[0..<segEnd])
                    if !line.isEmpty, !body(line, 0) { return false }
                }
                carry = Data(raw[0..<segEnd])
                return true
            }
            guard keepGoing, !Task.isCancelled else { return }
            end = start
        }
    }

    /// Each complete line from the start, oldest first. `body` returns false to stop.
    static func linesForward(_ url: URL, _ body: (UnsafeRawBufferPointer) -> Bool) throws {
        let h = try open(url)
        defer { try? h.close() }
        var carry = Data()
        while true {
            let data = (try h.read(upToCount: chunk)) ?? Data()
            let eof = data.isEmpty
            carry.append(data)
            let consumed = carry.withUnsafeBytes { raw -> Int? in
                var segStart = 0
                for i in newlines(raw) {
                    if i > segStart, !body(UnsafeRawBufferPointer(rebasing: raw[segStart..<i])) { return nil }
                    segStart = i + 1
                }
                if eof, segStart < raw.count, !body(UnsafeRawBufferPointer(rebasing: raw[segStart...])) { return nil }
                return segStart
            }
            guard let consumed, !eof, !Task.isCancelled else { return }
            carry.removeSubrange(0..<consumed)
        }
    }

    /// Offsets of every `\n`, via memchr (a byte loop is far slower on 100 MB).
    static func newlines(_ raw: UnsafeRawBufferPointer) -> [Int] {
        guard let base = raw.baseAddress else { return [] }
        var out: [Int] = [], from = 0
        while from < raw.count, let hit = memchr(base + from, 0x0A, raw.count - from) {
            let i = base.distance(to: UnsafeRawPointer(hit))
            out.append(i)
            from = i + 1
        }
        return out
    }

    private static func open(_ url: URL) throws -> FileHandle {
        do { return try FileHandle(forReadingFrom: url) } catch { throw AppError.io(error.localizedDescription) }
    }

    // MARK: - Pages

    /// The `limit` messages that end just before byte `before` (nil = end of
    /// file). Pages always break between messages, never inside a reply that
    /// Claude Code split across lines.
    static func page(_ url: URL, before: UInt64?, limit: Int) throws -> TranscriptPage {
        var newestFirst: [ChatMessage] = []
        var results: [String: ChatToolResult] = [:]
        var startOffset = before ?? UInt64.max
        // Assistant id of newestFirst.last (the oldest message so far).
        var oldestAssistantID: String?
        try linesBackward(url, end: before) { line, offset in
            guard let p = ChatLineParser.parse(line) else {
                startOffset = offset
                return true
            }
            if let m = p.message {
                if let aid = p.assistantID, aid == oldestAssistantID, var merged = newestFirst.popLast() {
                    merged.blocks = m.blocks + merged.blocks
                    merged.id = m.id
                    merged.timestamp = m.timestamp ?? merged.timestamp
                    newestFirst.append(merged)
                } else {
                    if newestFirst.count >= limit { return false }
                    newestFirst.append(m)
                }
                oldestAssistantID = p.assistantID
            }
            for r in p.results { results[r.id] = r.result }
            startOffset = offset
            return true
        }
        return TranscriptPage(messages: newestFirst.reversed(), results: results,
                              startOffset: startOffset == UInt64.max ? 0 : startOffset)
    }

    // MARK: - Whole-file scan

    struct Scan {
        var stats = ChatStats(messages: 0, firstActivity: nil, lastActivity: nil)
        var customTitle: String?
        var aiTitle: String?
        var summary: String?
        var prompt: String?
    }

    /// Message count, first/last activity and title candidates. Skips
    /// tool-result and tool-call lines undecoded (the bulk of a big file).
    static func scan(_ url: URL) throws -> Scan {
        var s = Scan()
        var first: String?, last: String?, lastAssistant: String?
        let toolResult = Array("\"tool_use_id\"".utf8), text = Array("\"type\":\"text\"".utf8)
        let assistant = Array("\"type\":\"assistant\"".utf8), user = Array("\"type\":\"user\"".utf8)
        try linesForward(url) { line in
            if ChatLineParser.contains(line, assistant), !ChatLineParser.contains(line, text) { return true }
            if ChatLineParser.contains(line, user), ChatLineParser.contains(line, toolResult) { return true }
            guard let p = ChatLineParser.parse(line) else { return true }
            if let c = p.customTitle { s.customTitle = c }
            if let a = p.aiTitle { s.aiTitle = a }
            if s.summary == nil { s.summary = p.summary }
            if s.prompt == nil { s.prompt = p.prompt }
            guard let m = p.message else { return true }
            if let t = p.timestamp { first = first ?? t; last = t }
            switch m.role {
            case .user: s.stats.messages += 1
            case .assistant:
                let hasText = m.blocks.contains { if case .text = $0 { true } else { false } }
                if hasText, p.assistantID != lastAssistant {
                    s.stats.messages += 1
                    lastAssistant = p.assistantID
                }
            case .notice: break
            }
            return true
        }
        s.stats.firstActivity = first.flatMap(ChatLineParser.parseDate)
        s.stats.lastActivity = last.flatMap(ChatLineParser.parseDate)
        return s
    }
}

/// Whole-file stats, cached by path + size + mtime so re-opening a project
/// never rescans an unchanged 100 MB transcript. List-row scans run one at a
/// time (scrolling must not start dozens of big reads); the open chat's scan
/// runs right away beside them.
actor ChatStatsCache {
    static let shared = ChatStatsCache()
    private struct Key: Equatable { var size: UInt64, mtime: UInt64 }
    private var entries: [String: (key: Key, stats: ChatStats)] = [:]

    private nonisolated static func key(_ url: URL) -> Key {
        Key(size: ArchiverFS.size(url) ?? 0, mtime: ArchiverFS.mtimeEpoch(url) ?? 0)
    }

    private func cached(_ url: URL, _ key: Key) -> ChatStats? {
        entries[url.path].flatMap { $0.key == key ? $0.stats : nil }
    }

    private func store(_ url: URL, _ key: Key, _ stats: ChatStats) { entries[url.path] = (key, stats) }

    /// Serialized on the actor.
    func queued(_ url: URL) throws -> ChatStats {
        let key = Self.key(url)
        if let hit = cached(url, key) { return hit }
        let stats = try Self.scan(url)
        store(url, key, stats)
        return stats
    }

    nonisolated func now(_ url: URL) async throws -> ChatStats {
        let key = Self.key(url)
        if let hit = await cached(url, key) { return hit }
        let stats = try Self.scan(url)
        await store(url, key, stats)
        return stats
    }

    private nonisolated static func scan(_ url: URL) throws -> ChatStats {
        let stats = try ChatReader.scan(url).stats
        if Task.isCancelled { throw AppError.cancelled("stats scan cancelled") }
        return stats
    }
}
