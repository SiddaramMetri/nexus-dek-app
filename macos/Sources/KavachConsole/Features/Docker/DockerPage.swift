import KavachCore
import SwiftUI

/// Docker: what images, containers, volumes and build cache take on disk, and
/// removing what nothing uses. Read-only until you confirm, and it never starts
/// Docker or Colima — when they're down it just says so.
struct DockerPage: View {
    @Environment(AppModel.self) private var model
    @Bindable private var d = DockerModel.shared

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Docker", subtitle: subtitle) { headerActions }
            content
        }
        .onAppear { d.refresh() }
    }

    private var subtitle: String {
        guard let s = d.snapshot, d.phase == .ready else {
            return "Images, containers, volumes and build cache"
        }
        var parts = ["\(Format.bytes(s.totalBytes)) used", "\(Format.bytes(s.reclaimableBytes)) reclaimable"]
        if let ctx = s.context { parts.append("context \(ctx)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var headerActions: some View {
        HStack(spacing: 10) {
            if d.loading || d.measuring {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(d.loading ? "Reading…" : "Measuring volumes…").font(.callout).foregroundStyle(.secondary)
                }
            }
            Button { d.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(d.loading || d.busy)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch d.phase {
        case .idle:
            loadingPlaceholder
        case let .unavailable(why):
            unavailable(why)
        case let .failed(error):
            VStack {
                ErrorPanel(error: error) { d.refresh() }
                Spacer()
            }
            .padding(24)
        case .ready:
            if let s = d.snapshot { ready(s) } else { loadingPlaceholder }
        }
    }

    /// Same layout as the loaded page, redacted — nothing jumps when data lands.
    private var loadingPlaceholder: some View {
        VStack(spacing: 0) {
            DockerOverview(snapshot: nil, select: { _ in })
                .redacted(reason: .placeholder)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            Divider()
            VStack(spacing: 10) {
                ProgressView()
                Text("Asking Docker what it's using…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func unavailable(_ why: DockerUnavailable) -> some View {
        switch why {
        case .notRunning:
            EmptyState(symbol: "moon.zzz", title: "Docker isn't running",
                       message: "Start Colima (or Docker Desktop) to see what it's using. "
                           + "This tab never starts Docker for you.",
                       action: ("Check again", { d.refresh() }))
        case .notResponding:
            EmptyState(symbol: "hourglass", title: "Docker isn't responding",
                       message: "The Docker daemon didn't answer within a few seconds. "
                           + "If Colima is still starting, check again in a moment.",
                       action: ("Check again", { d.refresh() }))
        case .notInstalled:
            EmptyState(symbol: "cube.box", title: "Docker isn't installed",
                       message: "No docker command was found on this Mac.")
        }
    }

    private func ready(_ s: DockerSnapshot) -> some View {
        VStack(spacing: 0) {
            DockerOverview(snapshot: s) { d.section = $0 }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            Divider()
            HStack(spacing: 0) {
                DockerSectionView(d: d)
                    .frame(maxWidth: .infinity)
                Divider()
                DockerQuickActions(d: d, snapshot: s)
                    .frame(width: 290)
            }
        }
    }
}
