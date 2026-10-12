import NexusCore
import SwiftUI

/// Claude Chats — master-detail (Notes/Mail pattern): projects on the left,
/// the selected project's live + archived chats and their actions on the right.
/// One-shot data: it only changes through our own mutations, which reload it.
struct ArchiverPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var projects: [ClaudeProject]?
    @ViewState private var archived: [ArchivedProject]?
    @ViewState private var loadError: AppError?
    @ViewState private var selection: String?
    @ViewState private var settingsOpen = false

    private var loaded: Bool { projects != nil && archived != nil }
    private var rows: [ArchiverRow] { ArchiverRow.build(projects: projects ?? [], archived: archived ?? []) }

    var body: some View {
        let rows = rows
        let active = rows.first { $0.id == selection } ?? rows.first
        VStack(spacing: 0) {
            PageHeader(title: "Claude Chats", subtitle: subtitle(rows)) {
                Button { settingsOpen = true } label: {
                    Label("Archive settings", systemImage: "slider.horizontal.3")
                }
                .labelStyle(.iconOnly)
                .help("Archive settings")
            }
            Divider()
            if let loadError {
                ErrorPanel(error: loadError) { Task { await load() } }
                    .padding([.horizontal, .top], 24)
            }
            HStack(alignment: .top, spacing: 16) {
                projectList(rows, active: active)
                    .frame(width: 280)
                    .frame(maxHeight: .infinity)
                detail(active)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(24)
        }
        .task { await load() }
        .sheet(isPresented: $settingsOpen) { ArchiveSettingsSheet() }
    }

    private func subtitle(_ rows: [ArchiverRow]) -> String {
        guard loaded else { return "Claude chat archive" }
        let live = rows.reduce(0) { $0 + ($1.live?.sessions ?? 0) }
        let bytes = (archived ?? []).reduce(UInt64(0)) { $0 + $1.totalBytes }
        return "\(rows.count) projects · \(live) live chats · \(Format.bytes(bytes)) archived"
    }

    // MARK: - Master

    private func projectList(_ rows: [ArchiverRow], active: ArchiverRow?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Projects").font(.headline).padding(.horizontal, 14).frame(height: 40)
            Divider()
            if !loaded {
                List { ForEach(0..<6, id: \.self) { _ in ArchiverProjectRow(row: nil) } }
                    .listStyle(.plain).scrollContentBackground(.hidden).redacted(reason: .placeholder)
                    .disabled(true)
            } else if rows.isEmpty {
                Text("Nothing in ~/.claude/projects.").font(.callout).foregroundStyle(.secondary).padding(14)
                Spacer(minLength: 0)
            } else {
                List(selection: Binding(get: { active?.id }, set: { if let id = $0 { selection = id } })) {
                    ForEach(rows) { ArchiverProjectRow(row: $0).tag($0.id) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .card(padding: 0)
    }

    // MARK: - Detail

    @ViewBuilder
    private func detail(_ active: ArchiverRow?) -> some View {
        if !loaded {
            VStack(alignment: .leading, spacing: 12) {
                Text("Project name").font(.headline)
                Text("/path/to/the/project/folder").font(.caption)
                ForEach(0..<6, id: \.self) { _ in Text("A chat title placeholder line").font(.callout) }
                Spacer(minLength: 0)
            }
            .redacted(reason: .placeholder)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        } else if let active {
            ArchiverDetail(row: active, reload: load).id(active.id)
        } else {
            EmptyState(symbol: "folder", title: "No Claude projects",
                       message: "Nothing found in ~/.claude/projects on this machine.")
                .card(padding: 0)
        }
    }

    // MARK: - Data

    private func load() async {
        async let p = ClaudeArchiver.projects()
        async let a = ClaudeArchiver.archived()
        do {
            (projects, archived) = try await (p, a)
            loadError = nil
        } catch {
            loadError = AppError.from(error)
            if projects == nil { projects = [] }
            if archived == nil { archived = [] }
        }
    }
}

/// Project row: name, original path, counts. `nil` renders a skeleton row.
private struct ArchiverProjectRow: View {
    let row: ArchiverRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row?.displayName ?? "Project name").font(.body.weight(.medium)).lineLimit(1)
            Text(row?.subtitle ?? "/Users/me/Documents/project").font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Text(counts).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .help(row?.subtitle ?? "")
    }

    private var counts: String {
        guard let row else { return "12 live · 3 archived" }
        var s = "\(row.live?.sessions ?? 0) live · \(row.archived?.chats.count ?? 0) archived"
        if let cache = row.live?.cacheBytes { s += " · \(Format.bytes(cache)) cache" }
        return s
    }
}
