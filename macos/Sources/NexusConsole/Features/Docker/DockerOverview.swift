import NexusCore
import SwiftUI

/// Four tiles from `docker system df`: size, count and reclaimable per type.
/// Clicking one opens that section below.
struct DockerOverview: View {
    let snapshot: DockerSnapshot?
    let select: (DockerModel.Section) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(DockerModel.Section.allCases) { section in
                Button { select(section) } label: { tile(section) }
                    .buttonStyle(.plain)
                    .help("Show \(section.label.lowercased())")
            }
        }
    }

    private func tile(_ section: DockerModel.Section) -> some View {
        let u = snapshot?.usage(kind(section))
        return VStack(alignment: .leading, spacing: 4) {
            Label(section.label, systemImage: symbol(section))
                .font(.callout).foregroundStyle(.secondary)
            Text(Format.bytes(u?.bytes ?? 0))
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(detail(section, u)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            let reclaimable = u?.reclaimable ?? 0
            Text(reclaimable > 0 ? "\(Format.bytes(reclaimable)) reclaimable" : "Nothing reclaimable")
                .font(.caption.weight(reclaimable > 0 ? .medium : .regular).monospacedDigit())
                .foregroundStyle(reclaimable > 0 ? Color.primary : Color.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func detail(_ section: DockerModel.Section, _ u: DockerUsage?) -> String {
        guard let u else { return "—" }
        switch section {
        case .images: return "\(u.total) image\(u.total == 1 ? "" : "s") · \(u.active) in use"
        case .containers: return "\(u.total) container\(u.total == 1 ? "" : "s") · \(u.active) running"
        case .volumes: return "\(u.total) volume\(u.total == 1 ? "" : "s") · \(u.active) in use"
        case .buildCache: return "\(u.total) cache entr\(u.total == 1 ? "y" : "ies")"
        }
    }

    private func kind(_ s: DockerModel.Section) -> DockerUsageKind {
        switch s {
        case .images: .images
        case .containers: .containers
        case .volumes: .volumes
        case .buildCache: .buildCache
        }
    }

    private func symbol(_ s: DockerModel.Section) -> String {
        switch s {
        case .images: "square.stack.3d.up"
        case .containers: "shippingbox"
        case .volumes: "externaldrive"
        case .buildCache: "hammer"
        }
    }
}
