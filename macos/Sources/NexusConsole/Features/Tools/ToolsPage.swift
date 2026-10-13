import AppKit
import NexusCore
import SwiftUI

/// Developer tools installed on this Mac — AI CLIs, runtimes, package
/// managers, infra CLIs and editor/terminal apps — with their install
/// method, latest version, and a one-click update that runs in the terminal.
struct ToolsPage: View {
    @Environment(AppModel.self) private var model

    private var store: ToolsStore { .shared }

    var body: some View {
        @Bindable var store = store
        let visible = store.visible()

        VStack(spacing: 0) {
            PageHeader(title: "Tools", subtitle: subtitle) {
                HStack(spacing: 8) {
                    if !store.updatable.isEmpty {
                        Button { store.updateAll(model: model) } label: {
                            Label("Update all (\(store.updatable.count))", systemImage: "arrow.up.circle")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    CheckUpdatesButton(isChecking: store.isChecking, checkedAt: store.cache.checkedAt) {
                        Task { await store.checkAll(model, redetect: true) }
                    }
                    .disabled(store.isChecking || store.isDetecting)
                }
            }
            HStack(spacing: 8) {
                SearchField(prompt: "Search tools…", text: $store.query).frame(width: 220)
                Picker("Filter", selection: $store.filter) {
                    ForEach(ToolFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text(checkedLabel).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
            Divider()

            content(visible)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await store.appear(model) }
    }

    /// "18 tools · 3 updates available".
    private var subtitle: String {
        guard let tools = store.tools else { return "Looking for developer tools on this Mac…" }
        let n = tools.count, m = store.updateCount
        var parts = ["\(n) \(n == 1 ? "tool" : "tools")"]
        if store.cache.checkedAt != nil || m > 0 {
            parts.append(m == 0 ? "no updates available" : "\(m) \(m == 1 ? "update" : "updates") available")
        }
        if store.isChecking { parts.append("checking…") }
        return parts.joined(separator: " · ")
    }

    private var checkedLabel: String {
        guard let at = store.cache.checkedAt else { return "Never checked" }
        let secs = Date().timeIntervalSince(at)
        if secs < 60 { return "Checked just now" }
        if secs < 3600 { return "Checked \(Int(secs / 60)) min ago" }
        return "Checked \(Format.relative(at))"
    }

    @ViewBuilder
    private func content(_ visible: [DevTool]) -> some View {
        if store.tools == nil {
            ToolsSkeleton().card(padding: 0).padding(24)
        } else if store.tools?.isEmpty == true {
            EmptyState(symbol: "wrench.and.screwdriver", title: "No developer tools found",
                       message: "Claude Code, Node.js, Homebrew, editors and other dev tools show up here once installed.",
                       action: ("Look again", { Task { await store.detect(model) } }))
        } else if visible.isEmpty {
            EmptyState(symbol: "magnifyingglass", title: store.filter == .updates ? "Everything is up to date" : "No matches",
                       message: store.filter == .updates ? nil : "Try a different search or filter.")
        } else {
            list(visible)
        }
    }

    /// One card; the list scrolls inside it under the fixed header.
    private func list(_ visible: [DevTool]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { i, tool in
                    if i > 0 { Divider() }
                    ToolRow(
                        tool: tool,
                        status: store.status(tool),
                        isChecking: store.checking.contains(tool.id),
                        updateLaunched: store.launched.contains(tool.id),
                        onUpdate: { store.update(tool, model: model) },
                        onRecheck: { Task { await store.recheck(tool, model: model) } })
                }
            }
        }
        .card(padding: 0)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(24)
    }
}

/// "Check for updates" whose icon becomes a spinner while checking (fixed
/// size, so the swap never shifts its neighbours).
private struct CheckUpdatesButton: View {
    let isChecking: Bool
    let checkedAt: Date?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                ZStack {
                    if isChecking {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 14, height: 14)
                Text("Check for updates")
            }
        }
        .keyboardShortcut("r", modifiers: .command)
        .help(checkedAt.map { "Last checked \(Format.time($0)) (⌘R)" } ?? "Check every tool for a newer version (⌘R)")
    }
}
