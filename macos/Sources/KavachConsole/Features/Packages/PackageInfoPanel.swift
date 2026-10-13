import KavachCore
import SwiftUI

/// Detail pane for the selected package: `brew info`, fetched on selection
/// and cached for five minutes.
struct PackageInfoPanel: View {
    @Environment(AppModel.self) private var model
    let name: String
    let onClose: () -> Void

    @ViewState private var details: PackageDetails?
    @ViewState private var error: AppError?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(name)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close info")
                    .accessibilityLabel("Close info")
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            Divider()

            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task(id: name) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let details {
            PackageDetailsView(details: details)
        } else if let error {
            ErrorPanel(error: error, retry: { Task { await load() } })
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 8)
        }
    }

    private func load() async {
        details = nil
        error = nil
        do {
            details = try await PackagesStore.shared.info(name, PackagesBackend(brew: model.brew))
        } catch {
            // Switching rows cancels the in-flight `brew info` — not an error.
            if !Task.isCancelled { self.error = AppError.from(error) }
        }
    }
}

private struct PackageDetailsView: View {
    let details: PackageDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let desc = details.description {
                Text(desc).font(.callout).foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let version = details.version {
                    GridRow {
                        Text("Version").foregroundStyle(.tertiary)
                        Text(version).font(.system(.caption, design: .monospaced))
                    }
                }
                GridRow {
                    Text("Type").foregroundStyle(.tertiary)
                    Text((details.isCask ? "Cask" : "Formula") + (details.isService ? " · service" : ""))
                }
            }
            .font(.caption)

            if let homepage = details.homepage {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Homepage").font(.caption).foregroundStyle(.tertiary)
                    Text(homepage).font(.caption).foregroundStyle(.secondary)
                }
            }

            if !details.dependencies.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dependencies (\(details.dependencies.count))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                    PackageChipsLayout(spacing: 4) {
                        ForEach(details.dependencies, id: \.self) { dep in
                            Text(dep)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
    }
}

/// Left-to-right wrapping layout for dependency chips.
private struct PackageChipsLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let next = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if next > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row(indices: [i], width: size.width, height: size.height)
            } else {
                row.indices.append(i)
                row.width = next
                row.height = max(row.height, size.height)
            }
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
