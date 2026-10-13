import KavachCore
import SwiftUI

/// Right pane: one chat, read-only, newest page first ("Load earlier" walks
/// back through the file), with Continue in Claude Code up top. The parent
/// keys this view by chat id, so only the open chat is ever held in memory.
struct ChatConversationView: View {
    let ref: ChatRef

    @Environment(AppModel.self) private var model
    @ViewState private var messages: [ChatMessage]?
    @ViewState private var results: [String: ChatToolResult] = [:]
    /// Byte offset to load earlier messages from; 0 = the start was reached.
    @ViewState private var earlierFrom: UInt64 = 0
    @ViewState private var loadingEarlier = false
    @ViewState private var loadError: AppError?
    @ViewState private var stats: ChatStats?
    @ViewState private var query = ""
    @ViewState private var expanded: Set<String> = []

    private var shown: [ChatMessage] {
        let all = messages ?? []
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? all : all.filter { $0.searchText.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .card(padding: 0)
        .task { await loadLatest() }
    }

    // MARK: - Header

    private var header: some View {
        let problem = ChatLaunch.resumeProblem(ref)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(ref.chat.title).font(.headline).lineLimit(1).truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { ChatLaunch.resume(ref, model: model) } label: {
                    Label("Continue in Claude Code", systemImage: "terminal")
                }
                .buttonStyle(.borderedProminent)
                .disabled(problem != nil)
                .help(problem ?? "Opens the terminal in \(ref.folder ?? "the project folder") and resumes this chat")
                Menu {
                    Button { ChatLaunch.newChat(folder: ref.folder, projectName: ref.projectName, model: model) } label: {
                        Label("New chat here", systemImage: "square.and.pencil")
                    }
                    .disabled(ClaudeChats.launchProblem(folder: ref.folder) != nil)
                    Button { ChatLaunch.copyResumeCommand(ref, model: model) } label: {
                        Label("Copy resume command", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More chat actions")
            }
            HStack(spacing: 10) {
                Text(subtitle).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                PaneSearchField(prompt: "Search this chat", text: $query).frame(maxWidth: 220)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let stats {
            parts.append("\(stats.messages) message\(stats.messages == 1 ? "" : "s")")
            if let last = stats.lastActivity { parts.append("last active \(Format.relative(last))") }
        } else {
            parts.append("Counting messages…")
        }
        if ref.chat.bytes > 0 { parts.append(Format.bytes(ref.chat.bytes)) }
        if case .archived = ref.location { parts.append("archived") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Messages

    @ViewBuilder
    private var content: some View {
        if let loadError, messages == nil {
            ErrorPanel(error: loadError) { Task { await loadLatest() } }
                .padding(14)
            Spacer(minLength: 0)
        } else if let messages {
            if messages.isEmpty && earlierFrom == 0 {
                EmptyState(symbol: "bubble.left.and.bubble.right", title: "No messages",
                           message: "This chat has no prompts or replies to show.")
            } else {
                transcript
            }
        } else {
            skeleton
        }
    }

    private var transcript: some View {
        let shown = shown
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if earlierFrom > 0 {
                        Button { loadEarlier(proxy) } label: {
                            if loadingEarlier { ProgressView().controlSize(.small) } else { Text("Load earlier messages") }
                        }
                        .disabled(loadingEarlier)
                        .frame(maxWidth: .infinity)
                    }
                    if !query.isEmpty {
                        Text(searchNote(shown.count)).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(shown) { m in
                        ChatMessageView(message: m, results: results, expanded: $expanded).id(m.id)
                    }
                }
                .padding(16)
            }
            .defaultScrollAnchor(.bottom)
        }
    }

    private func searchNote(_ n: Int) -> String {
        let found = n == 0 ? "No matches" : "\(n) matching message\(n == 1 ? "" : "s")"
        return earlierFrom > 0 ? found + " in the loaded part — load earlier messages to search further" : found
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(0..<4, id: \.self) { i in
                HStack {
                    if i.isMultiple(of: 2) { Spacer(minLength: 80) }
                    Text("A placeholder line for a chat message that is loading")
                        .padding(10)
                        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                    if !i.isMultiple(of: 2) { Spacer(minLength: 80) }
                }
            }
            Spacer(minLength: 0)
        }
        .redacted(reason: .placeholder)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    // MARK: - Data

    private func loadLatest() async {
        let ref = ref
        async let counted = try? ClaudeChats.stats(ref.location, file: ref.file, queued: false)
        do {
            let page = try await ClaudeChats.page(ref.location, file: ref.file)
            messages = page.messages
            results = page.results
            earlierFrom = page.startOffset
            loadError = nil
        } catch {
            loadError = AppError.from(error)
        }
        stats = await counted
    }

    private func loadEarlier(_ proxy: ScrollViewProxy) {
        guard earlierFrom > 0, !loadingEarlier else { return }
        let ref = ref, before = earlierFrom, anchor = shown.first?.id
        loadingEarlier = true
        Task {
            defer { loadingEarlier = false }
            do {
                let page = try await ClaudeChats.page(ref.location, file: ref.file, before: before)
                messages = page.messages + (messages ?? [])
                results.merge(page.results) { current, _ in current }
                earlierFrom = page.startOffset
                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
            } catch {
                model.report(error)
            }
        }
    }
}
