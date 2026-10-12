import NexusCore
import SwiftUI

/// Live-list age filter — "Archive…" archives exactly what's shown.
enum ChatAgeFilter: Int, CaseIterable, Identifiable {
    case all = 0, d7 = 7, d14 = 14, d30 = 30, d90 = 90
    var id: Int { rawValue }
    var label: String { self == .all ? "All" : "\(rawValue)d+" }
}

/// Detail pane: BOTH sides of the selected project — live chats on top
/// (filter by age, select, archive or delete), archived below (restore or
/// delete). The two lists share the height; an empty one collapses to its
/// header. The parent keys this view by row id, so all state resets per project.
/// Every action's confirm is a native alert raised inside NexusCore.
struct ArchiverDetail: View {
    let row: ArchiverRow
    let reload: () async -> Void

    @Environment(AppModel.self) private var model
    @ViewState private var live: [ArchivedChat]?
    @ViewState private var filter: ChatAgeFilter = .all
    @ViewState private var selLive: Set<String> = []
    @ViewState private var selArch: Set<String> = []
    @ViewState private var busy = false

    private var liveChats: [ArchivedChat] { live ?? [] }
    private var shownLive: [ArchivedChat] {
        ArchivedChat.olderThan(liveChats, days: filter.rawValue, now: UInt64(Date().timeIntervalSince1970))
    }
    private var archChats: [ArchivedChat] { row.archived?.chats ?? [] }
    private var canRestore: Bool { row.live != nil }

    var body: some View {
        let shown = shownLive
        VStack(spacing: 0) {
            header
            if row.live != nil {
                Divider()
                liveSection(shown)
                    .frame(maxHeight: shown.isEmpty ? nil : .infinity, alignment: .top)
            }
            Divider()
            archivedSection
                .frame(maxHeight: archChats.isEmpty ? nil : .infinity, alignment: .top)
            if shown.isEmpty && archChats.isEmpty { Spacer(minLength: 0) }
        }
        .card(padding: 0)
        .task { await loadLive() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.displayName).font(.headline).lineLimit(1)
            Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Text(stats).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var stats: String {
        let bytes = (row.live?.totalBytes ?? 0) + (row.archived?.totalBytes ?? 0)
        var s = "\(row.live?.sessions ?? 0) live · \(archChats.count) archived · \(Format.bytes(bytes))"
        if let cache = row.live?.cacheBytes { s += " · \(Format.bytes(cache)) VSCode cache" }
        return s
    }

    // MARK: - Live

    private func liveSection(_ shown: [ArchivedChat]) -> some View {
        let allSelected = !shown.isEmpty && shown.allSatisfy { selLive.contains($0.file) }
        return VStack(spacing: 0) {
            // Fixed height: the trailing side swaps between the filter and the
            // selection toolbar — the bar must never change size.
            sectionBar(
                title: filter == .all ? "Live chats · \(liveChats.count)" : "Live chats · \(shown.count) of \(liveChats.count)",
                allSelected: allSelected, disabled: shown.isEmpty, selectAllLabel: "Select all live chats",
                toggleAll: { selLive = allSelected ? [] : Set(shown.map(\.file)) }
            ) {
                if !selLive.isEmpty {
                    Button { archive(Array(selLive)) } label: { Label("Archive \(selLive.count)", systemImage: "archivebox") }
                        .disabled(busy)
                    deleteButton("Delete \(selLive.count)") { deleteLive(Array(selLive)) }
                    Button("Clear") { selLive = [] }.buttonStyle(.borderless)
                } else {
                    Picker("Show chats older than", selection: $filter) {
                        ForEach(ChatAgeFilter.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    if filter != .all && !shown.isEmpty {
                        Button { cutoffArchive() } label: { Label("Archive \(shown.count)…", systemImage: "archivebox") }
                            .disabled(busy)
                    }
                }
            }
            Divider()
            if live == nil {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(0..<3, id: \.self) { _ in Text("A chat title placeholder").font(.callout) }
                }
                .redacted(reason: .placeholder)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            } else if shown.isEmpty {
                note(liveChats.isEmpty ? "No live chats." : "No chats older than \(filter.rawValue) days.")
            } else {
                ArchiverChatList(chats: shown, selected: $selLive, actions: [
                    ChatAction(label: "Archive", symbol: "archivebox", disabled: busy) { archive([$0]) },
                    ChatAction(label: "Delete", symbol: "trash", destructive: true, disabled: busy) { deleteLive([$0]) },
                ])
            }
        }
    }

    // MARK: - Archived

    private var archivedSection: some View {
        let chats = archChats
        let allSelected = !chats.isEmpty && chats.allSatisfy { selArch.contains($0.file) }
        let restoreHelp = canRestore ? "" : "Original project no longer exists"
        return VStack(spacing: 0) {
            sectionBar(
                title: "Archived · \(chats.count)", allSelected: allSelected, disabled: chats.isEmpty,
                selectAllLabel: "Select all archived chats",
                toggleAll: { selArch = allSelected ? [] : Set(chats.map(\.file)) }
            ) {
                if !selArch.isEmpty {
                    Button { restore(Array(selArch)) } label: {
                        Label("Restore \(selArch.count)", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(busy || !canRestore)
                    .help(restoreHelp)
                    deleteButton("Delete \(selArch.count)") { deleteArchived(Array(selArch)) }
                    Button("Clear") { selArch = [] }.buttonStyle(.borderless)
                }
            }
            Divider()
            if chats.isEmpty {
                note("Nothing archived yet" + (row.live != nil && !liveChats.isEmpty
                    ? " — select live chats above to archive them." : "."))
            } else {
                ArchiverChatList(chats: chats, selected: $selArch, actions: [
                    ChatAction(label: "Restore", symbol: "arrow.uturn.backward", disabled: busy || !canRestore,
                               help: restoreHelp) { restore([$0]) },
                    ChatAction(label: "Delete", symbol: "trash", destructive: true, disabled: busy) { deleteArchived([$0]) },
                ])
            }
        }
    }

    // MARK: - Building blocks

    private func sectionBar<Trailing: View>(
        title: String, allSelected: Bool, disabled: Bool, selectAllLabel: String,
        toggleAll: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 8) {
            ChatCheckbox(isOn: allSelected, label: selectAllLabel, action: toggleAll).disabled(disabled)
            Text(title).font(.subheadline.weight(.semibold).monospacedDigit())
            Spacer(minLength: 8)
            trailing().controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.quaternary.opacity(0.35))
    }

    /// Permanent actions read as destructive: red, trash symbol, and a native
    /// destructive confirm behind them (the second step).
    private func deleteButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) { Label(title, systemImage: "trash") }
            .foregroundStyle(.red)
            .disabled(busy)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
    }

    // MARK: - Actions

    private func loadLive() async {
        guard let dir = row.live?.dirName else { return }
        do { live = try await ClaudeArchiver.sessions(dirName: dir) } catch {
            if live == nil { live = [] }
            model.report(error)
        }
    }

    /// Run a mutation: toast its message, then reload both sides. A dismissed
    /// confirm (`cancelled`) stays silent and changes nothing.
    private func run(_ body: @escaping () async throws -> String?) {
        busy = true
        Task {
            defer { busy = false }
            do {
                if let msg = try await body() { model.toast(msg) }
            } catch {
                model.report(error)
                if AppError.from(error).isCancelled { return }
            }
            await loadLive()
            await reload()
        }
    }

    private func archive(_ files: [String]) {
        guard let dir = row.live?.dirName else { return }
        run {
            let r = try await ClaudeArchiver.archiveFiles(dirName: dir, files: files, confirmer: model.confirmer)
            selLive = []
            return "Archived \(count(r.done))\(skipped(r)) — restart VSCode to rebuild its session cache smaller."
        }
    }

    private func cutoffArchive() {
        guard let dir = row.live?.dirName, filter != .all else { return }
        let days = filter.rawValue
        run {
            let r = try await ClaudeArchiver.archive(dirName: dir, cutoffDays: days, confirmer: model.confirmer)
            return r.moved > 0 ? "Archived \(count(r.moved)) — restart VSCode to rebuild its session cache smaller." : nil
        }
    }

    private func restore(_ files: [String]) {
        guard let dir = row.live?.dirName else { return }
        run {
            let r = try await ClaudeArchiver.restore(dirName: dir, files: files, confirmer: model.confirmer)
            selArch = []
            return "Restored \(count(r.done))\(skipped(r)) — restart VSCode to see them."
        }
    }

    private func deleteArchived(_ files: [String]) {
        guard let folder = row.archived?.folder else { return }
        run {
            let r = try await ClaudeArchiver.delete(folder: folder, files: files, confirmer: model.confirmer)
            selArch = []
            return "Deleted \(r.done) archived chat\(r.done == 1 ? "" : "s") permanently"
        }
    }

    private func deleteLive(_ files: [String]) {
        guard let dir = row.live?.dirName else { return }
        run {
            let r = try await ClaudeArchiver.deleteLive(dirName: dir, files: files, confirmer: model.confirmer)
            selLive = []
            return "Deleted \(count(r.done)) permanently"
        }
    }

    private func count(_ n: Int) -> String { "\(n) chat\(n == 1 ? "" : "s")" }
    private func skipped(_ r: BulkResult) -> String { r.skipped.isEmpty ? "" : " (\(r.skipped.count) skipped)" }
}
