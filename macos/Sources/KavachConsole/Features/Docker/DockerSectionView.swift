import KavachCore
import SwiftUI

/// The selected type's list: toolbar, rows with round checkboxes, and a red
/// remove footer. Build cache is a single row with its own button.
struct DockerSectionView: View {
    @Environment(AppModel.self) private var model
    @Bindable var d: DockerModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if d.section == .buildCache {
                DockerBuildCacheView(d: d)
            } else {
                if d.section == .volumes { volumeWarning }
                list
                Divider()
                footer
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Section", selection: $d.section) {
                ForEach(DockerModel.Section.allCases) { s in
                    Text(s == .buildCache ? s.label : "\(s.label) \(d.count(s))").tag(s)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer(minLength: 8)
            if d.section != .buildCache {
                Picker("Sort", selection: $d.sort) {
                    ForEach(DockerModel.Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().fixedSize()
                SearchField(prompt: "Filter…", text: $d.query).frame(width: 180)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var volumeWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Volumes can hold database data. Only volumes no container uses can be deleted, and deleting one is permanent.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var list: some View {
        switch d.section {
        case .images:
            let rows = d.images
            List {
                ForEach(rows) { DockerImageRow(d: d, image: $0) }
            }
            .listStyle(.inset)
            .overlay { if rows.isEmpty { emptyText("No images") } }
        case .containers:
            let rows = d.containers
            List {
                ForEach(rows) { DockerContainerRow(d: d, container: $0) }
            }
            .listStyle(.inset)
            .overlay { if rows.isEmpty { emptyText("No containers") } }
        case .volumes:
            let rows = d.volumes
            List {
                ForEach(rows) { DockerVolumeRow(d: d, volume: $0) }
            }
            .listStyle(.inset)
            .overlay { if rows.isEmpty { emptyText("No volumes") } }
        case .buildCache:
            EmptyView()
        }
    }

    private func emptyText(_ what: String) -> some View {
        Text(d.query.isEmpty ? what : "Nothing matches “\(d.query)”").foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            DockerSelectBox(mark: d.mark, enabled: true) { d.toggleAllVisible() }
                .help("Select every removable row shown")
            selectMenu
            let (n, bytes) = d.selectionSummary
            Text(n == 0 ? hint : "\(n) selected" + (bytes.map { " · \(Format.bytes($0))" } ?? ""))
                .foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button(role: .destructive) { d.removeSelected(model: model) } label: {
                Label(removeLabel(n, bytes), systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(n == 0 || d.busy)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var selectMenu: some View {
        Menu("Select") {
            switch d.section {
            case .images:
                Button("Dangling images") { d.selectDanglingImages() }
                Button("All unused images") { d.imageSel = Set(d.images.filter(\.removable).map(\.id)) }
            case .containers:
                Button("All stopped containers") { d.containerSel = Set(d.containers.filter(\.removable).map(\.id)) }
            case .volumes:
                Button("Unused anonymous volumes") { d.selectAnonymousVolumes() }
                Button("All unused volumes") { d.volumeSel = Set(d.volumes.filter(\.removable).map(\.name)) }
            case .buildCache:
                EmptyView()
            }
            Divider()
            Button("None") { d.clearSelection() }
        }
        .fixedSize()
    }

    private var hint: String {
        switch d.section {
        case .images: "Images in use by a container are locked"
        case .containers: "Running containers are locked — stop them first"
        case .volumes: "Volumes a container uses are locked"
        case .buildCache: ""
        }
    }

    private func removeLabel(_ n: Int, _ bytes: UInt64?) -> String {
        let verb = d.section == .volumes ? "Delete" : "Remove"
        guard n > 0 else { return verb }
        return "\(verb) \(n)" + (bytes.map { " · \(Format.bytes($0))" } ?? "")
    }
}

/// Build cache: one row with its size and a clear button.
struct DockerBuildCacheView: View {
    @Environment(AppModel.self) private var model
    @Bindable var d: DockerModel

    var body: some View {
        let u = d.snapshot?.usage(.buildCache)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "hammer").font(.title3).foregroundStyle(.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Build cache").fontWeight(.semibold)
                    Text("\(u?.total ?? 0) entr\(u?.total == 1 ? "y" : "ies") · layers kept to speed up docker build")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.bytes(u?.bytes ?? 0)).monospacedDigit()
                    Text("\(Format.bytes(u?.reclaimable ?? 0)) reclaimable")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button(role: .destructive) { d.prune(.buildCache, model: model) } label: {
                    Label("Clear build cache", systemImage: "trash")
                }
                .disabled((u?.reclaimable ?? 0) == 0 || d.busy)
            }
            .card()
            Text("Clearing is safe: Docker rebuilds layers the next time you build, so the first build after is slower.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.top, 10)
            Spacer()
        }
        .padding(20)
    }
}
