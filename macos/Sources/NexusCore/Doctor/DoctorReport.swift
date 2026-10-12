import Foundation

extension Tag {
    public var label: String {
        switch self {
        case .speed: "Speed"
        case .storage: "Storage"
        case .info: "Info"
        }
    }
}

/// Markdown export + how the report is laid out on the page.
public enum DoctorReport {
    /// Markdown report of the current findings — what Doctor found, with honest tags.
    public static func markdown(_ findings: [Finding], dateLabel: String) -> String {
        let sorted = DoctorEngine.sorted(findings)
        let attention = sorted.filter { $0.severity != .green }
        let healthy = sorted.filter { $0.severity == .green }
        var lines = ["# Nexus Doctor report — \(dateLabel)", "", "## Needs attention (\(attention.count))"]
        lines += attention.isEmpty
            ? ["- Nothing — all clear."]
            : attention.map { "- **[\($0.tag.label)]** \($0.summary)\n  \($0.explain)" }
        lines += ["", "## Healthy (\(healthy.count))"]
        lines += healthy.map { "- **[\($0.tag.label)]** \($0.summary)" }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static var desktop: URL { Paths.home.appendingPathComponent("Desktop", isDirectory: true) }

    /// Write a report to ~/Desktop/nexus-doctor-report-<epoch>.md and return
    /// its path. The filename is composed here — never caller-supplied.
    public static func export(_ content: String) async throws -> String {
        try await Task.detached {
            let url = desktop.appendingPathComponent("nexus-doctor-report-\(Journal.nowEpoch).md")
            do { try content.write(to: url, atomically: true, encoding: .utf8) } catch {
                throw AppError.io(error.localizedDescription)
            }
            return url.path
        }.value
    }

    // MARK: - Layout

    // Probes that emit an overview + per-item rows (ollama models, extensions):
    // the item rows nest INSIDE the overview card instead of flooding the list.
    // Overviews are recognized by their authored summary shape — rename those
    // summaries and this grouping breaks.
    private static let overviewPatterns: [String: String] = [
        OllamaProbe.models.id: #"^\d+ ollama models?\b"#,
        VSCodeDoctor.extensionAudit.id: #"^\d+ extensions ·"#,
        BrowserProbes.extensions.id: #"^\d+ extensions? ·"#,
    ]

    public static func isOverview(_ f: Finding) -> Bool {
        guard let pattern = overviewPatterns[f.probeId] else { return false }
        return f.summary.range(of: pattern, options: .regularExpression) != nil
    }

    static func isNestedChild(_ f: Finding) -> Bool {
        overviewPatterns[f.probeId] != nil && !isOverview(f)
    }

    /// Top-level rows: nested children are hidden under their overview (a
    /// child whose overview is absent still renders standalone).
    public static func rows(_ displayed: [Finding]) -> [Finding] {
        displayed.filter { f in
            !isNestedChild(f) || !displayed.contains { $0.probeId == f.probeId && isOverview($0) }
        }
    }

    /// The rows an overview nests; nil for a finding that isn't an overview.
    public static func children(of f: Finding, in displayed: [Finding]) -> [Finding]? {
        guard isOverview(f) else { return nil }
        return displayed.filter { $0.probeId == f.probeId && !isOverview($0) }
    }

    public struct Group: Equatable, Sendable {
        public let title: String
        public let findings: [Finding]
    }

    private static let browserLabels = ["Chrome", "Brave", "Edge"]

    /// Browser tab: one section per browser (per-browser summaries start with
    /// the browser name), a dedicated Extensions section, then power & audio.
    public static func browserGroups(_ rows: [Finding]) -> [Group] {
        let order = browserLabels + ["Extensions", "Power & audio"]
        var groups: [String: [Finding]] = [:]
        for f in rows {
            let g = f.probeId == BrowserProbes.extensions.id
                ? "Extensions"
                : browserLabels.first { f.summary.hasPrefix($0) } ?? "Power & audio"
            groups[g, default: []].append(f)
        }
        return order.compactMap { g in groups[g].map { Group(title: g, findings: $0) } }
    }
}
