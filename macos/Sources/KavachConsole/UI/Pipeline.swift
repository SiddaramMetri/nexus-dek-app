import SwiftUI

/// One stage in a `Pipeline`.
struct PipelineStep: Identifiable {
    enum State: Equatable { case pending, running, done, skipped, failed }

    var id: String { title }
    let title: String
    let symbol: String
    var state: State
    /// Short status under the title ("Ready", "166 found", "Verified").
    var detail: String
}

/// Horizontal stage tracker: an icon tile per step joined by connectors.
/// Done = green tile + check badge, pending/skipped = dashed tile + minus
/// badge, running = accent tile + spinner, failed = red. A connector turns
/// green once the step after it has started.
struct Pipeline: View {
    let steps: [PipelineStep]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                StepView(step: step).frame(width: 104)
                if i < steps.count - 1 {
                    Rectangle()
                        .fill(steps[i + 1].state == .pending ? Color(nsColor: .separatorColor) : Color.green)
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 19)
                        .animation(.snappy, value: steps[i + 1].state)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }
}

private struct StepView: View {
    let step: PipelineStep

    var body: some View {
        VStack(spacing: 6) {
            tile.overlay(alignment: .bottomTrailing) { badge.offset(x: 5, y: 5) }
            Text(step.title).font(.callout.weight(.semibold)).lineLimit(1)
            Text(step.detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.title), \(step.detail)")
    }

    private var tint: Color {
        switch step.state {
        case .done: .green
        case .running: .accentColor
        case .failed: .red
        case .pending, .skipped: .secondary
        }
    }

    private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        let solid = step.state == .done || step.state == .running || step.state == .failed
        return Image(systemName: step.symbol)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(solid ? tint.opacity(0.14) : Color.clear, in: shape)
            .overlay {
                if solid {
                    shape.strokeBorder(tint.opacity(0.7), lineWidth: 1.2)
                } else {
                    shape.strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
    }

    @ViewBuilder
    private var badge: some View {
        Group {
            switch step.state {
            case .done: Image(systemName: "checkmark").foregroundStyle(.white).background(Circle().fill(.green).frame(width: 16, height: 16))
            case .failed: Image(systemName: "xmark").foregroundStyle(.white).background(Circle().fill(.red).frame(width: 16, height: 16))
            case .running: ProgressView().controlSize(.mini).background(Circle().fill(.background).frame(width: 16, height: 16))
            case .pending, .skipped:
                Image(systemName: "minus").foregroundStyle(.white).background(Circle().fill(Color.secondary).frame(width: 16, height: 16))
            }
        }
        .font(.system(size: 8, weight: .heavy))
        .frame(width: 16, height: 16)
    }
}
