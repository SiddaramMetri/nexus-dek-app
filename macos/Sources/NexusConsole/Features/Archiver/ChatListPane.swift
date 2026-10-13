import NexusCore
import SwiftUI

/// Middle pane: the selected project's chats — live or archived — with search,
/// an age filter and checkbox multi-select for the bulk actions. Clicking a row
/// opens the chat on the right. The parent keys this view by project, so all
/// state resets per project. Every action's confirm is a native alert raised
/// inside NexusCore.
struct ChatListPane: View {
    let row: ArchiverRow
    let openID: String?
    let onOpen: (ChatRef?) -> Void
    let reload: () async -> Void

    enum Scope: Hashable { case live, archived }

    /// Rows render in pages of this size; "Show more" appends the next page.
    static let page = 60

    @Environment(AppModel.self) private var model
    @ViewState private var live: [ArchivedChat]?
    @ViewState private var scope: Scope
    @ViewState private var filter: ChatAgeFilter = .all
    @ViewState private var query = ""
    @ViewState private var selected: Set<String> = []
    @ViewState private var visible = ChatListPane.page
    @ViewState private var busy = false

    init(row: ArchiverRow, openID: String?, onOpen: @escaping (ChatRef?) -> Void, reload: @escaping () async -> Void) {
        self.row = row
        self.openID = openID
        self.onOpen = onOpen
        self.reload = reload
        _scope = ViewState(initialValue: row.live != nil ? .live : .archived)
    }

    private var archivedChats: [ArchivedChat] { row.archived?.chats ?? [] }
    private var source: [ArchivedChat] { scope == .live ? live ?? [] : archivedChats }
    private var shown: [ArchivedChat] {
        let aged = ArchivedChat.olderThan(source, days: filter.rawValue, now: UInt64(Date().timeIntervalSince1970))
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? aged : aged.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }
    private var location: ChatLocation? {
        switch scope {
        case .live: row.live.map { .live(dirName: $0.dirName) }
        case .archived: row.archived.map { .archived(folder: $0.folder) }
        }
    }
    private var folder: String? { row.live?.realPath }

    var body: some View {
        let shown = shown
        // Bulk actions only ever touch chats that are on screen.
        let picked = shown.map(\.file).filter(selected.contains)
        VStack(spacing: 0) {
            header
            Divider()
            selectionBar(shown, picked: picked)
            Divider()
            list(shown, picked: Set(picked))
        }
        .card(padding: 0)
        .task { await loadLive() }
        .onChange(of: scope) { _, _ in selected = []; visible = Self.page }
        .onChange(of: query) { _, _ in visible = Self.page }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayName).font(.headline).lineLimit(1)
                    Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(row.subtitle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                let problem = ClaudeChats.launchProblem(folder: folder)
                Button { ChatLaunch.newChat(folder: folder, projectName: row.displayName, model: model) } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .labelStyle(.iconOnly)
                .disabled(problem != nil)
                .help(problem ?? "Start a new Claude Code chat in this folder")
            }
            if row.live != nil {
                Picker("Chats", selection: $scope) {
                    Text("Live · \(live?.count ?? row.live?.sessions ?? 0)").tag(Scope.live)
                    Text("Archived · \(archivedChats.count)").tag(Scope.archived)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack(spacing: 8) {
                SearchField(prompt: "Search chats", text: $query)
                Picker("Age", selection: $filter) {
                    ForEach(ChatAgeFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("Show only chats older than…")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Selection bar

    /// Fixed height: the trailing side swaps between the cutoff action and the
    /// selection toolbar — the bar must never change size.
    private func selectionBar(_ shown: [ArchivedChat], picked: [String]) -> some View {
        let allSelected = !shown.isEmpty && picked.count == shown.count
        return HStack(spacing: 8) {
            ChatCheckbox(isOn: allSelected, label: "Select all shown chats") {
                selected = allSelected ? [] : Set(shown.map(\.file))
            }
            .disabled(shown.isEmpty)
            if picked.isEmpty {
                Text(countLabel(shown.count)).font(.subheadline.weight(.semibold).monospacedDigit())
                Spacer(minLength: 6)
                // The core's cutoff archive matches the age filter alone, so offer it only unsearched.
                if scope == .live, filter != .all, query.isEmpty, !shown.isEmpty {
                    Button { cutoffArchive() } label: { Label("Archive \(shown.count)…", systemImage: "archivebox") }
                        .disabled(busy)
                }
            } else {
                Text("\(picked.count) selected").font(.subheadline.weight(.semibold).monospacedDigit())
                Spacer(minLength: 6)
                if scope == .live {
                    Button("Archive") { archive(picked) }.disabled(busy)
                } else {
                    Button("Restore") { restore(picked) }
                        .disabled(busy || row.live == nil)
                        .help(row.live == nil ? "Original project no longer exists" : "")
                }
                Button("Delete", role: .destructive) { delete(picked) }
                    .foregroundStyle(.red)
                    .disabled(busy)
                Button("Clear") { selected = [] }.buttonStyle(.borderless)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.quaternary.opacity(0.35))
    }

    private func countLabel(_ n: Int) -> String {
        let total = source.count
        let noun = "chat\(total == 1 ? "" : "s")"
        return n == total ? "\(total) \(noun)" : "\(n) of \(total) \(noun)"
    }

    // MARK: - List

    @ViewBuilder
    private func list(_ shown: [ArchivedChat], picked: Set<String>) -> some View {
        if scope == .live && live == nil {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(0..<6, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A chat title placeholder line")
                        Text("12 messages · 3 days ago").font(.caption)
                    }
                }
                Spacer(minLength: 0)
            }
            .redacted(reason: .placeholder)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
        } else if shown.isEmpty {
            Text(emptyNote).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(14)
        } else if let location {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(shown.prefix(visible))) { chat in
                        let ref = ref(chat, location)
                        ChatListRow(chat: chat, location: location, isChecked: picked.contains(chat.file),
                                    isOpen: ref.id == openID, toggle: { toggle(chat.file) }, open: { onOpen(ref) })
                            .contextMenu { menu(ref) }
                    }
                    if shown.count > visible {
                        let rest = shown.count - visible
                        Button("Show \(min(Self.page, rest)) more (\(rest) remaining)") { visible += Self.page }
                            .buttonStyle(.borderless)
                            .padding(10)
                    }
                }
                .padding(6)
            }
        }
    }

    private var emptyNote: String {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return "No chats match “\(query)”." }
        if filter != .all, !source.isEmpty { return "No chats older than \(filter.rawValue) days." }
        if scope == .archived {
            return "Nothing archived yet" + (row.live != nil ? " — select live chats to archive them." : ".")
        }
        return "No live chats."
    }

    @ViewBuilder
    private func menu(_ ref: ChatRef) -> some View {
        Button("Open") { onOpen(ref) }
        if scope == .live {
            Button("Continue in Claude Code") { ChatLaunch.resume(ref, model: model) }
                .disabled(ChatLaunch.resumeProblem(ref) != nil)
        }
        Button("Copy resume command") { ChatLaunch.copyResumeCommand(ref, model: model) }
        Divider()
        if scope == .live {
            Button("Archive") { archive([ref.file]) }.disabled(busy)
        } else {
            Button("Restore") { restore([ref.file]) }.disabled(busy || row.live == nil)
        }
        Button("Delete…", role: .destructive) { delete([ref.file]) }.disabled(busy)
    }

    private func ref(_ chat: ArchivedChat, _ location: ChatLocation) -> ChatRef {
        ChatRef(location: location, chat: chat, folder: folder, projectName: row.displayName)
    }

    private func toggle(_ file: String) {
        if selected.contains(file) { selected.remove(file) } else { selected.insert(file) }
    }

    // MARK: - Actions

    private func loadLive() async {
        guard let dir = row.live?.dirName else { return }
        do { live = try await ClaudeArchiver.sessions(dirName: dir) } catch {
            if live == nil { live = [] }
            model.report(error)
        }
    }

    /// Run a mutation: toast its message, close the open chat if it moved,
    /// then reload both sides. A dismissed confirm (`cancelled`) stays silent
    /// and changes nothing.
    private func run(_ files: [String], _ body: @escaping () async throws -> String?) {
        busy = true
        let closesOpenChat = location.map { loc in files.contains { ChatRef.id(loc, file: $0) == openID } } ?? false
        Task {
            defer { busy = false }
            do {
                if let msg = try await body() { model.toast(msg) }
                selected.subtract(files)
                if closesOpenChat { onOpen(nil) }
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
        run(files) {
            let r = try await ClaudeArchiver.archiveFiles(dirName: dir, files: files, confirmer: model.confirmer)
            return "Archived \(count(r.done))\(skipped(r)) — restart VSCode to rebuild its session cache smaller."
        }
    }

    private func cutoffArchive() {
        guard let dir = row.live?.dirName, filter != .all else { return }
        let days = filter.rawValue, files = shown.map(\.file)
        run(files) {
            let r = try await ClaudeArchiver.archive(dirName: dir, cutoffDays: days, confirmer: model.confirmer)
            return r.moved > 0 ? "Archived \(count(r.moved)) — restart VSCode to rebuild its session cache smaller." : nil
        }
    }

    private func restore(_ files: [String]) {
        guard let dir = row.live?.dirName else { return }
        run(files) {
            let r = try await ClaudeArchiver.restore(dirName: dir, files: files, confirmer: model.confirmer)
            return "Restored \(count(r.done))\(skipped(r)) — restart VSCode to see them."
        }
    }

    private func delete(_ files: [String]) {
        switch scope {
        case .live:
            guard let dir = row.live?.dirName else { return }
            run(files) {
                let r = try await ClaudeArchiver.deleteLive(dirName: dir, files: files, confirmer: model.confirmer)
                return "Deleted \(count(r.done)) permanently"
            }
        case .archived:
            guard let folder = row.archived?.folder else { return }
            run(files) {
                let r = try await ClaudeArchiver.delete(folder: folder, files: files, confirmer: model.confirmer)
                return "Deleted \(r.done) archived chat\(r.done == 1 ? "" : "s") permanently"
            }
        }
    }

    private func count(_ n: Int) -> String { "\(n) chat\(n == 1 ? "" : "s")" }
    private func skipped(_ r: BulkResult) -> String { r.skipped.isEmpty ? "" : " (\(r.skipped.count) skipped)" }
}
