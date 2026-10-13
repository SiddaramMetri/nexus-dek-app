import Foundation

/// Display formatters — same output as the TS `shared/lib/format.ts`.
public enum Format {
    public static func bytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        let kb = Double(bytes) / 1024
        if kb < 1 { return "\(bytes) B" }
        if kb < 1024 { return "\(Int(kb.rounded())) KB" }
        let mb = kb / 1024
        if mb < 1024 { return mb < 10 ? String(format: "%.1f MB", mb) : "\(Int(mb.rounded())) MB" }
        return String(format: "%.1f GB", mb / 1024)
    }

    /// 3d 4h · 5h 50m · 2m 15s · 8s
    public static func duration(_ secs: UInt64?) -> String {
        guard let secs else { return "—" }
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60, s = secs % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    public static func percent(_ cpu: Double?) -> String {
        guard let cpu else { return "—" }
        return String(format: "%.1f%%", cpu)
    }

    /// "just now" · "5h ago" · "yesterday" · "12 days ago" · "3 weeks ago" · "4 months ago"
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let secs = max(0, Int(now.timeIntervalSince(date)))
        let days = secs / 86_400
        if secs < 3_600 { return "just now" }
        if days == 0 { return "\(secs / 3_600)h ago" }
        if days == 1 { return "yesterday" }
        if days < 14 { return "\(days) days ago" }
        if days < 61 { return "\(days / 7) weeks ago" }
        return "\(days / 30) months ago"
    }

    /// "Jul 14, 8:05 AM"
    public static func time(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// redis → Redis · postgresql@18 → Postgresql · mongodb-community → Mongodb Community
    public static func formulaDisplayName(_ formula: String) -> String {
        let base = bareFormula(formula).split(separator: "@", omittingEmptySubsequences: false).first ?? ""
        return base.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
