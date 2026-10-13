import KavachCore
import SwiftUI

/// Installed packages: sortable native table. Selecting a row opens its info
/// panel; per-row actions are an Upgrade button (when outdated and unpinned)
/// plus a menu, mirrored in the row context menu.
struct PackagesTable: View {
    let packages: [PackageItem]
    @Binding var selection: PackageItem.ID?
    let serviceNames: Set<String>
    let upgrading: Set<String>
    let onUpgrade: (PackageItem) -> Void
    let onAddToServices: (PackageItem) -> Void
    let onUninstall: (PackageItem) -> Void

    @ViewState private var sortOrder: [KeyPathComparator<PackageItem>] = []

    private var rows: [PackageItem] { sortOrder.isEmpty ? packages : packages.sorted(using: sortOrder) }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { p in PackageNameCell(pkg: p) }
                .width(min: 180, ideal: 280)
            TableColumn("Version", value: \.version) { p in PackageVersionCell(pkg: p) }
                .width(min: 160, ideal: 230)
            TableColumn("") { p in actions(p) }
                .width(min: 130, ideal: 150, max: 170)
        }
        .contextMenu(forSelectionType: PackageItem.ID.self) { ids in
            if let p = ids.first.flatMap(find) { menuItems(p) }
        }
        .overlay {
            if packages.isEmpty {
                Text("No packages found.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func find(_ id: PackageItem.ID) -> PackageItem? { packages.first { $0.id == id } }

    private func actions(_ p: PackageItem) -> some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            if p.outdated && !p.pinned {
                let busy = upgrading.contains(p.name)
                Button(busy ? "Upgrading…" : "Upgrade") { onUpgrade(p) }
                    .controlSize(.small)
                    .disabled(busy)
            }
            Menu { menuItems(p) } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Package actions")
            .accessibilityLabel("Package actions")
        }
    }

    @ViewBuilder
    private func menuItems(_ p: PackageItem) -> some View {
        Button { selection = p.id } label: { Label("View info", systemImage: "info.circle") }
        if serviceNames.contains(p.name) {
            Button { onAddToServices(p) } label: { Label("Add to Services", systemImage: "plus.circle") }
        }
        Divider()
        Button(role: .destructive) { onUninstall(p) } label: { Label("Uninstall…", systemImage: "trash") }
    }
}

private struct PackageNameCell: View {
    let pkg: PackageItem

    var body: some View {
        HStack(spacing: 6) {
            Text(pkg.name).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            Text(pkg.kind.rawValue)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                .fixedSize()
            if pkg.pinned {
                Label("pinned", systemImage: "pin.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PackageVersionCell: View {
    let pkg: PackageItem

    var body: some View {
        HStack(spacing: 6) {
            Text(pkg.version)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(pkg.version)
            if pkg.outdated { PackageOutdatedBadge(latestVersion: pkg.latestVersion) }
        }
    }
}

/// "6.0.5 available" — status = color plus label, never color alone.
struct PackageOutdatedBadge: View {
    let latestVersion: String?

    var body: some View {
        Text(latestVersion.map { "\($0) available" } ?? "Outdated")
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.14), in: Capsule())
            .foregroundStyle(.orange)
            .fixedSize()
    }
}
