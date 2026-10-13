import AppKit
import NexusCore
import SwiftUI

/// Dev cleanup: every node_modules and other regenerable dev folder under the
/// home folder, grouped by project. Pick a project on the left, see its
/// folders on the right, move what you don't need to the Trash.
struct CleanupPage: View {
    @Environment(AppModel.self) private var model
    @Bindable private var c = CleanupModel.shared

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Dev cleanup", subtitle: subtitle) { headerActions }
            Pipeline(steps: c.steps)
                .card(padding: 0)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            if c.trashedBytes > 0 { trashHint }
            Divider()
            content
        }
        // `--args -NexusAutoScan YES` starts a scan on open (used for screenshots).
        .onAppear { if !c.scanned, UserDefaults.standard.bool(forKey: "NexusAutoScan") { c.scan() } }
    }

    private var subtitle: String {
        guard c.foundDone, !c.items.isEmpty else {
            return "node_modules, build output, venvs and other folders that regenerate"
        }
        var s = "\(c.items.count) folders in \(c.projectCount) projects · \(Format.bytes(c.totalBytes))"
        s += c.scanning ? " so far" : " · \(Format.bytes(c.reclaimableBytes)) in dead or stale projects"
        return s
    }

    @ViewBuilder
    private var headerActions: some View {
        if c.scanning {
            Button("Cancel") { c.cancelScan() }
        } else if c.scanned {
            if !c.deadItems.isEmpty {
                Button(role: .destructive) { c.cleanAllDead(model: model) } label: {
                    Label("Clean all dead · \(Format.bytes(c.deadItems.compactMap(\.bytes).reduce(0, +)))", systemImage: "sparkles")
                }
                .help("Moves every folder in the \(c.deadProjectCount) dead projects to the Trash — you'll see the full list first")
                .disabled(c.trash == .running)
            }
            Button { c.scan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !c.scanned {
            intro
        } else if !c.foundDone {
            VStack(spacing: 10) {
                ProgressView()
                Text("Looking through your home folder…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if c.items.isEmpty {
            EmptyState(symbol: "checkmark.circle", title: "Nothing to clean",
                       message: "No node_modules or other regenerable folders in your home folder.")
        } else {
            toolbar
            Divider()
            HSplitView {
                CleanupProjectList(c: c)
                    .frame(minWidth: 300, idealWidth: 380, maxWidth: 520)
                CleanupProjectDetail(c: c)
                    .frame(minWidth: 420, maxWidth: .infinity)
            }
            Divider()
            footer
        }
    }

    /// Space only comes back once the Trash is emptied — say so, with the fix.
    private var trashHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash.circle.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Format.bytes(c.trashedBytes)) is waiting in the Trash").fontWeight(.medium)
                Text("Your disk gets the space back once the Trash is emptied.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Trash") {
                NSWorkspace.shared.open(Paths.home.appendingPathComponent(".Trash", isDirectory: true))
            }
            Button(role: .destructive) { c.emptyTrash(model: model) } label: {
                if c.emptyingTrash { ProgressView().controlSize(.small) } else { Text("Empty Trash…") }
            }
            .disabled(c.emptyingTrash)
            Button { c.trashedBytes = 0 } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Dismiss")
        }
        .card(padding: 12)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var intro: some View {
        VStack(spacing: 14) {
            Text("Find folders you can safely remove").font(.title2.weight(.semibold))
            Text("Lists every project's node_modules, framework caches, build output, Python venvs, Rust target, Pods and Gradle caches — "
                 + "grouped by project, with sizes. Only those folders are ever removed: your code, package.json and lockfiles stay.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
            Button { c.scan() } label: { Label("Scan home folder", systemImage: "magnifyingglass") }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Text("Read-only until you confirm. Removed folders go to the Trash. Projects used in the last \(DevCleaner.lockDays) days are locked.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Show", selection: $c.filter) {
                ForEach(CleanupModel.Filter.allCases) { f in Text(label(f)).tag(f) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 320)
            Picker("Kind", selection: $c.kind) {
                Text("All kinds").tag(JunkKind?.none)
                Divider()
                ForEach(JunkKind.allCases.filter { k in c.items.contains { $0.kind == k } }) { k in
                    Text(k.label).tag(JunkKind?.some(k))
                }
            }
            .labelsHidden().fixedSize()
            Toggle("Over 500 MB", isOn: $c.bigOnly).toggleStyle(.checkbox)
            Spacer()
            Picker("Sort", selection: $c.sort) {
                ForEach(CleanupModel.GroupSort.allCases) { Text("Sort by \($0.rawValue.lowercased())").tag($0) }
            }
            .labelsHidden().fixedSize()
            SearchField(prompt: "Filter by path…", text: $c.query).frame(width: 200)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private func label(_ f: CleanupModel.Filter) -> String {
        "\(f.rawValue) \(c.items.filter { f.includes($0.category) }.count)"
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Menu("Select") {
                Button("Dead") { c.select([.dead]) }
                Button("Dead and stale") { c.select([.dead, .stale]) }
                Button("Everything unlocked") { c.select([.dead, .stale, .active]) }
                Divider()
                Button("None") { c.selection = [] }
            }
            .fixedSize()
            let sel = c.selectedItems
            let projects = Set(sel.map(\.groupRoot)).count
            Text(sel.isEmpty ? "Tick folders to remove"
                 : "\(sel.count) folder\(sel.count == 1 ? "" : "s") in \(projects) project\(projects == 1 ? "" : "s") · \(Format.bytes(c.selectedBytes))")
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) { c.moveToTrash(sel, model: model) } label: {
                Label(sel.isEmpty ? "Move to Trash" : "Move \(sel.count) to Trash · \(Format.bytes(c.selectedBytes))",
                      systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(sel.isEmpty || c.trash == .running || c.scanning)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}
