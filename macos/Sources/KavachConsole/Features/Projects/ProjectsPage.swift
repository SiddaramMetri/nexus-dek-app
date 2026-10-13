import AppKit
import KavachCore
import SwiftUI

/// Every coding project on this Mac on one screen — running or not — with its
/// git state, dev servers and removable disk. Read-only apart from Start/Stop
/// (the Ports tab's) and pinning.
struct ProjectsPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var killTarget: PortInfo?

    private var store: ProjectsModel { .shared }
    private var ports: PortsStore { .shared }

    var body: some View {
        @Bindable var store = store
        let facts = store.facts
        let shown = store.shown(facts)

        VStack(spacing: 0) {
            PageHeader(title: "Projects", subtitle: subtitle(shown: shown.count, facts: facts)) {
                HStack(spacing: 8) {
                    SearchField(prompt: "Project name or path…", text: $store.query)
                        .frame(width: 230)
                    FetchRefreshButton(isFetching: store.loading) { Task { await store.refresh() } }
                        .disabled(store.loading)
                }
            }
            ProjectsToolbar(filter: $store.filter, sort: $store.sort, cleanupScanned: !facts.removable.isEmpty)
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
            Divider()

            content(shown, facts: facts)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await store.refreshIfStale() }
        .task { await pollPorts() }
        .onChange(of: store.filter) { _, f in if f == .unsaved { store.requestAllGit() } }
        .onChange(of: facts.running) { _, roots in store.adopt(portOwners: Array(roots)) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await ports.reload() }
        }
        .sheet(item: $killTarget) { PortKillSheet(target: $0) }
    }

    /// Live ports on the user's interval while the window is visible, as on the Ports tab.
    private func pollPorts() async {
        while !Task.isCancelled {
            if ports.snapshot == nil || NSApp.occlusionState.contains(.visible) { await ports.reload() }
            try? await Task.sleep(for: .milliseconds(max(1000, model.settings.pollIntervalMs)))
        }
    }

    /// "42 projects · 3 running", or "5 of 42 shown" while narrowed.
    private func subtitle(shown: Int, facts: ProjectFacts) -> String {
        guard store.loadedAt != nil || !store.projects.isEmpty else { return "Looking for projects in your home folder…" }
        let total = store.projects.count
        let updating = store.loadedAt == nil ? " · updating…" : ""
        if !store.query.trimmingCharacters(in: .whitespaces).isEmpty || store.filter != .all {
            var s = "\(shown) of \(total) shown"
            if store.filter == .unsaved, store.gitPending > 0 { s += " · checking git status…" }
            return s + updating
        }
        var parts = ["\(total) \(total == 1 ? "project" : "projects")"]
        let running = store.projects.filter { facts.running.contains($0.root) }.count
        if running > 0 { parts.append("\(running) running") }
        return parts.joined(separator: " · ") + updating
    }

    @ViewBuilder
    private func content(_ shown: [ProjectInfo], facts: ProjectFacts) -> some View {
        let q = store.query.trimmingCharacters(in: .whitespaces)
        if store.loadedAt == nil && store.projects.isEmpty {
            ProjectsSkeleton().padding(24)
        } else if store.projects.isEmpty {
            EmptyState(symbol: "square.stack.3d.down.right", title: "No projects found",
                       message: "Git repositories in your home folder, and folders running a dev server, show up here.",
                       action: ("Refresh", { Task { await store.refresh() } }))
        } else if shown.isEmpty {
            noMatches(q)
        } else {
            let livePorts = ports.snapshot?.ports ?? []
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 480), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(shown) { p in
                        ProjectOverviewCard(project: p, ports: livePorts, removable: facts.removable[p.root]) {
                            killTarget = $0
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    @ViewBuilder
    private func noMatches(_ q: String) -> some View {
        if !q.isEmpty {
            EmptyState(symbol: "magnifyingglass", title: "No matches", message: "No project matches “\(q)”.")
        } else {
            switch store.filter {
            case .all:
                EmptyState(symbol: "square.stack.3d.down.right", title: "No projects found")
            case .running:
                EmptyState(symbol: "play.circle", title: "Nothing running",
                           message: "Projects with a dev server listening on a port show up here.")
            case .unsaved:
                if store.gitPending > 0 {
                    EmptyState(symbol: "arrow.triangle.branch", title: "Checking git status…",
                               message: "\(store.gitPending) \(store.gitPending == 1 ? "project" : "projects") left to check.")
                } else {
                    EmptyState(symbol: "checkmark.circle", title: "No unsaved work",
                               message: "Every repository is committed and pushed.")
                }
            case .pinned:
                EmptyState(symbol: "pin", title: "No pinned projects",
                           message: "Pin a project from its ⋯ menu to keep it at the top.")
            }
        }
    }
}

/// Filter (segmented) on the left, sort menu on the right.
private struct ProjectsToolbar: View {
    @Binding var filter: ProjectFilter
    @Binding var sort: ProjectSort
    /// Sorting by removable size only means something after a Dev cleanup scan.
    let cleanupScanned: Bool

    var body: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $filter) {
                ForEach(ProjectFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Picker("Sort by", selection: $sort) {
                ForEach(ProjectSort.allCases) { s in
                    Text(s.rawValue).tag(s)
                        .disabled(s == .removable && !cleanupScanned)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help(cleanupScanned ? "Sort projects" : "Run a Dev cleanup scan to sort by removable size")
        }
    }
}

/// First-load placeholder: project-card shapes, no spinner.
private struct ProjectsSkeleton: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 480), spacing: 16, alignment: .top)], spacing: 16) {
            ForEach(0..<4, id: \.self) { _ in card }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(true)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                bar(height: 32).frame(width: 32)
                VStack(alignment: .leading, spacing: 6) {
                    bar(height: 14).frame(width: 140)
                    bar(height: 10).frame(width: 200)
                }
                Spacer()
            }
            HStack(spacing: 6) {
                bar(height: 18).frame(width: 80)
                bar(height: 18).frame(width: 64)
                bar(height: 18).frame(width: 96)
                Spacer()
            }
            bar(height: 72).frame(maxWidth: .infinity)
            Divider()
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { _ in bar(height: 20).frame(maxWidth: .infinity) }
            }
        }
        .card()
    }

    private func bar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(.quaternary).frame(height: height)
    }
}
