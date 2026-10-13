import AppKit
import KavachCore
import SwiftUI

/// Left: one row per project (repository), biggest first.
struct CleanupProjectList: View {
    @Bindable var c: CleanupModel

    var body: some View {
        let groups = c.groups
        let dupes = Set(Dictionary(grouping: groups, by: \.name).filter { $0.value.count > 1 }.keys)
        List(selection: Binding<String?>(get: { c.focused?.root }, set: { c.focusedGroup = $0 })) {
            ForEach(groups) { g in
                ProjectRow(c: c, group: g, showParent: dupes.contains(g.name)).tag(Optional(g.root))
            }
        }
        .listStyle(.inset)
        .overlay {
            if groups.isEmpty {
                Text("No folders match these filters.").foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProjectRow: View {
    @Bindable var c: CleanupModel
    let group: JunkGroup
    /// Two projects share this name — say which folder each lives in.
    let showParent: Bool

    var body: some View {
        HStack(spacing: 10) {
            SelectBox(mark: c.mark(group), enabled: !group.deletable.isEmpty) { c.toggle(group) }
                .help(group.deletable.isEmpty ? "Every folder here is locked — used recently" : "Select every unlocked folder in \(group.name)")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.name).fontWeight(.semibold).lineLimit(1)
                    if showParent {
                        Text("in \(((group.root as NSString).deletingLastPathComponent as NSString).lastPathComponent)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if group.lockedCount == group.items.count {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(abbreviatePath(group.root)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(group.items.count) folder\(group.items.count == 1 ? "" : "s") · \(lastUsed(group.lastUsedEpoch))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                SizeText(bytes: group.isMeasured ? group.bytes : nil, partial: group.bytes)
                CategoryChip(category: group.category, locked: group.lockedCount == group.items.count)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Right: the selected project's folders.
struct CleanupProjectDetail: View {
    @Environment(AppModel.self) private var model
    @Bindable var c: CleanupModel

    var body: some View {
        if let g = c.focused {
            VStack(spacing: 0) {
                header(g)
                Divider()
                List {
                    ForEach(g.items) { item in FolderRow(c: c, group: g, item: item) }
                }
                .listStyle(.inset)
            }
        } else {
            EmptyState(symbol: "folder", title: "Select a project")
        }
    }

    private func header(_ g: JunkGroup) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder.fill").font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(g.name).font(.title3.weight(.semibold))
                Text(abbreviatePath(g.root)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Text("\(g.items.count) removable folder\(g.items.count == 1 ? "" : "s") · \(Format.bytes(g.bytes))"
                     + (g.lockedCount > 0 ? " · \(g.lockedCount) locked" : ""))
                    .font(.callout).foregroundStyle(.secondary)
                GitChip(status: c.git[g.root] ?? nil, loading: c.gitLoading.contains(g.root))
                    .onAppear { c.loadGit(g.root) }
                    .onChange(of: g.root) { _, r in c.loadGit(r) }
            }
            Spacer()
            Button { reveal([g.root]) } label: { Label("Show in Finder", systemImage: "folder") }
            Button(c.mark(g) == .all ? "Deselect all" : "Select all") { c.toggle(g) }
                .disabled(g.deletable.isEmpty)
            Button(role: .destructive) { c.moveToTrash(g.deletable, model: model) } label: {
                Label("Trash all · \(Format.bytes(g.deletable.compactMap(\.bytes).reduce(0, +)))", systemImage: "trash")
            }
            .disabled(g.deletable.isEmpty || c.trash == .running || c.scanning)
        }
        .padding(16)
    }
}

private struct FolderRow: View {
    @Environment(AppModel.self) private var model
    @Bindable var c: CleanupModel
    let group: JunkGroup
    let item: JunkItem

    var body: some View {
        HStack(spacing: 10) {
            SelectBox(mark: c.selection.contains(item.id) ? .all : .none, enabled: !item.locked) { c.toggle(item) }
            Image(systemName: item.locked ? "lock.fill" : symbol)
                .foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.relativePath(of: item)).font(.body.monospaced()).lineLimit(1).truncationMode(.middle)
                Text("\(item.kind.label) · Rebuild: \(item.kind.rebuildCost) · \(item.kind.regenerate)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let keep = item.keepReason {
                    Label(keep, systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if let warning = item.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            SizeText(bytes: item.bytes, partial: nil).frame(width: 80, alignment: .trailing)
            Text(lastUsed(item.lastUsedEpoch)).foregroundStyle(.secondary).frame(width: 100, alignment: .trailing)
            CategoryChip(category: item.category, locked: item.locked, keepReason: item.keepReason).frame(width: 64)
            Button { reveal([item.path]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show in Finder")
            Button(role: .destructive) { c.moveToTrash([item], model: model) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help(item.keepReason ?? (item.locked ? "Locked — this project was used in the last \(DevCleaner.lockDays) days" : "Move to Trash"))
                .disabled(item.locked || c.trash == .running || c.scanning)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { c.toggle(item) }
    }

    private var symbol: String {
        switch item.kind {
        case .nodeModules: "shippingbox"
        case .jsFrameworkCache: "bolt"
        case .jsBuildOutput: "hammer"
        case .rustTarget: "gearshape.2"
        case .pythonVenv: "terminal"
        case .cocoaPods: "apple.logo"
        case .gradleCache: "cube"
        }
    }
}

// MARK: - Small pieces

/// Branch + unsaved-work state for the focused project.
private struct GitChip: View {
    let status: GitSafety.Status?
    let loading: Bool

    var body: some View {
        if let status {
            let warn = status.hasUnsavedWork
            Label {
                Text([status.branch, status.summary].compactMap { $0 }.joined(separator: " · "))
            } icon: {
                Image(systemName: warn ? "exclamationmark.triangle.fill" : "arrow.triangle.branch")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(warn ? Color.orange : Color.secondary)
            .help(warn ? "Unsaved git work here. Cleaning doesn't touch code, but it isn't backed up either." : "Git: nothing unsaved")
        } else if loading {
            ProgressView().controlSize(.mini)
        }
    }
}

/// Round macOS-style selection checkbox with a mixed state.
private struct SelectBox: View {
    let mark: CleanupModel.Mark
    let enabled: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: symbol)
            .font(.system(size: 16))
            .foregroundStyle(mark == .none ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(mark == .all ? "Selected" : mark == .some ? "Partly selected" : "Not selected")
    }

    private var symbol: String {
        switch mark {
        case .all: "checkmark.circle.fill"
        case .some: "minus.circle.fill"
        case .none: "circle"
        }
    }
}

private struct SizeText: View {
    let bytes: UInt64?
    /// Shown dimmed while a group is still being measured.
    let partial: UInt64?

    var body: some View {
        if let bytes {
            Text(Format.bytes(bytes)).monospacedDigit()
                .fontWeight(bytes >= CleanupModel.bigThreshold ? .semibold : .regular)
        } else if let partial, partial > 0 {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(Format.bytes(partial)).monospacedDigit().foregroundStyle(.secondary)
            }
        } else {
            ProgressView().controlSize(.mini)
        }
    }
}

private struct CategoryChip: View {
    let category: JunkItem.Category
    let locked: Bool
    var keepReason: String? = nil

    var body: some View {
        let (text, color, help) = style
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
            .help(help)
    }

    private var style: (String, Color, String) {
        if let keepReason { return ("Keep", .secondary, keepReason) }
        if locked { return ("In use", .secondary, "Used in the last \(DevCleaner.lockDays) days — locked") }
        return switch category {
        case .dead: ("Dead", .orange, "In Downloads, or untouched for over 6 months")
        case .stale: ("Stale", .yellow, "Untouched for 1–6 months")
        case .active: ("Active", .green, "Used within the last month")
        }
    }
}

private func abbreviatePath(_ path: String) -> String {
    let home = Paths.home.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

private func lastUsed(_ epoch: UInt64) -> String {
    epoch == 0 ? "—" : Format.relative(Date(timeIntervalSince1970: TimeInterval(epoch)))
}

private func reveal(_ paths: [String]) {
    NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
}
