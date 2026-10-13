import NexusCore
import SwiftUI

/// One-click cleanups, safest first. Each confirms natively with exactly what
/// goes and how much. There's deliberately no "prune everything" button.
struct DockerQuickActions: View {
    @Environment(AppModel.self) private var model
    @Bindable var d: DockerModel
    let snapshot: DockerSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Quick cleanup").font(.headline)
            Text("Each one asks first and says exactly what goes.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.bottom, 12)
            ForEach([DockerPrune.danglingImages, .stoppedContainers, .buildCache]) { p in
                row(p)
                Divider().padding(.vertical, 8)
            }
            row(.unusedVolumes)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Permanent. Volumes can hold database data. Docker 23+ removes only anonymous ones here; "
                     + "delete named volumes one by one in the list.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .padding(.top, 6)
            Spacer(minLength: 16)
            Text("This frees disk space; it doesn't make your Mac faster. With Colima the space is freed inside "
                 + "its VM disk, which macOS may not see shrink right away.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ p: DockerPrune) -> some View {
        let (n, bytes) = p.plan(snapshot)
        let empty = p == .buildCache ? (bytes ?? 0) == 0 : n == 0
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).fontWeight(.medium)
                Text(empty ? "Nothing to remove" : detail(p, n, bytes))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(role: .destructive) { d.prune(p, model: model) } label: {
                Text(p == .buildCache ? "Clear…" : p == .unusedVolumes ? "Delete…" : "Remove…")
            }
            .disabled(empty || d.busy)
            .help(p.confirmText(snapshot).message)
        }
    }

    private func detail(_ p: DockerPrune, _ n: Int, _ bytes: UInt64?) -> String {
        let size = bytes.map { " · \(Format.bytes($0))" } ?? (d.measuring ? " · measuring…" : "")
        switch p {
        case .danglingImages: return "\(n) untagged image\(n == 1 ? "" : "s")\(size)"
        case .stoppedContainers: return "\(n) stopped container\(n == 1 ? "" : "s")\(size)"
        case .buildCache: return "Up to \(Format.bytes(bytes ?? 0))"
        case .unusedVolumes: return "\(n) anonymous volume\(n == 1 ? "" : "s")\(size)"
        }
    }
}
