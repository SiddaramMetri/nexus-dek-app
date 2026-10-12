import NexusCore
import SwiftUI

extension Severity {
    var symbol: String {
        switch self {
        case .red: "exclamationmark.octagon.fill"
        case .yellow: "exclamationmark.triangle.fill"
        case .green: "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .red: .red
        case .yellow: .orange
        case .green: .green
        }
    }

    var accessibilityName: String {
        switch self {
        case .red: "Urgent"
        case .yellow: "Needs attention"
        case .green: "Healthy"
        }
    }
}

/// One report line: severity icon + one-line summary + honest tag. Healthy
/// rows stay a single line; red/yellow rows (and any row carrying an action,
/// steps or nested rows) disclose the explanation, guide steps and — when the
/// finding is automatable — a fix button whose result lands on the row.
struct FindingRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let finding: Finding
    /// Nested rows (one per ollama model / extension) shown inside this row
    /// when expanded, instead of as separate top-level rows.
    var subFindings: [Finding]?

    @ViewState private var open = false
    @ViewState private var running = false
    @ViewState private var result: String?
    @ViewState private var fixError: String?

    private var meta: FixMeta? { DoctorFix.meta(finding.fix) }

    private var expandable: Bool {
        finding.severity != .green || meta != nil || !(finding.guide ?? []).isEmpty || !(subFindings ?? []).isEmpty
    }

    // Two-line rows: summaries are authored as "Title · meta · meta" — the
    // first segment is the title, the rest becomes the muted meta line.
    private var parts: (title: String, meta: String) {
        let segs = finding.summary.components(separatedBy: " · ")
        return (segs[0], segs.dropFirst().joined(separator: " · "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if open {
                detail.transition(.opacity)
            }
        }
        .background(open ? Color.primary.opacity(0.035) : .clear)
    }

    private var header: some View {
        Button {
            guard expandable else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) { open.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: finding.severity.symbol)
                    .foregroundStyle(finding.severity.color)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(parts.title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.tail)
                    if !parts.meta.isEmpty {
                        Text(parts.meta).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(finding.tag.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
                // Non-expandable rows keep the chevron slot so tags align down the list.
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .opacity(expandable ? 1 : 0)
                    .frame(width: 14)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(finding.severity.accessibilityName): \(finding.summary), \(finding.tag.label)")
        .accessibilityAddTraits(expandable ? .isButton : [])
        .accessibilityValue(expandable ? (open ? "Expanded" : "Collapsed") : "")
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(finding.explain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 620, alignment: .leading)
                .textSelection(.enabled)

            if let subFindings, !subFindings.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(subFindings.enumerated()), id: \.element.id) { i, sf in
                        if i > 0 { Divider() }
                        FindingRow(finding: sf)
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            }

            if let guide = finding.guide, !guide.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(guide.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(i + 1).").monospacedDigit().foregroundStyle(.tertiary)
                            Text(step).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 620, alignment: .leading)
                .textSelection(.enabled)
            }

            if let meta, let fixId = finding.fix { fixArea(meta, fixId) }
        }
        .padding(.leading, 42)
        .padding(.trailing, 16)
        .padding(.top, 2)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func fixArea(_ meta: FixMeta, _ fixId: String) -> some View {
        if let result {
            Label("\(result) — run Scan again to refresh.", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 10) {
                fixButton(meta, fixId)
                if let fixError {
                    Label(fixError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // Destructive fixes are confirm-gated inside NexusCore by a native sheet —
    // one click here, the system alert does the asking.
    @ViewBuilder
    private func fixButton(_ meta: FixMeta, _ fixId: String) -> some View {
        let label = HStack(spacing: 6) {
            if running {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: meta.destructive ? "trash" : "wrench.and.screwdriver")
            }
            Text(meta.label)
        }
        if meta.destructive {
            Button(role: .destructive) { runFix(fixId) } label: { label }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(running)
        } else {
            Button { runFix(fixId) } label: { label }
                .buttonStyle(.borderedProminent)
                .disabled(running)
        }
    }

    private func runFix(_ fixId: String) {
        running = true
        fixError = nil
        Task {
            defer { running = false }
            do {
                result = try await DoctorFix.run(fixId, confirmer: model.confirmer)
            } catch {
                // A dismissed confirm is not a failure — stay silent.
                let e = AppError.from(error)
                if !e.isCancelled { fixError = e.message }
            }
        }
    }
}
