import AppKit
import NexusCore
import SwiftUI

/// Ports grouped by what they belong to: your projects, apps, macOS, other.
/// Polls on the user's interval only while the tab is shown and the window is
/// visible; refetches when the app is reactivated.
struct PortsPage: View {
    @Environment(AppModel.self) private var model

    @ViewState private var query = ""
    @ViewState private var killTarget: PortInfo?

    private var store: PortsStore { .shared }

    var body: some View {
        @Bindable var store = store
        let all = store.snapshot.map { PortSections.build($0, brewServices: brewPids) }
        let shown = store.snapshot.map { PortSections.build($0, brewServices: brewPids, query: query) }

        VStack(spacing: 0) {
            PageHeader(title: "Ports", subtitle: subtitle(all: all, shown: shown)) {
                HStack(spacing: 8) {
                    SearchField(prompt: "Port, process, project or app…", text: $query)
                        .frame(width: 230)
                    Picker("Scope", selection: $store.listeningOnly) {
                        Text("Listening").tag(true)
                        Text("All").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    FetchRefreshButton(isFetching: store.isFetching) { Task { await store.reload() } }
                }
            }
            .padding(.bottom, 8)
            Divider()

            content(shown)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: store.listeningOnly) { await poll() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.reload() }
        }
        .sheet(item: $killTarget) { PortKillSheet(target: $0) }
    }

    /// pid → formula for running Homebrew services.
    private var brewPids: [Int32: String] {
        Dictionary(model.brewServices.compactMap { s in s.pid.map { ($0, s.name) } }, uniquingKeysWith: { a, _ in a })
    }

    private func poll() async {
        while !Task.isCancelled {
            // Skip the lsof/ps shell-outs while the window is hidden to the tray.
            // The first load never waits: right after launch macOS hasn't reported the window visible yet.
            if store.snapshot == nil || NSApp.occlusionState.contains(.visible) { await store.reload() }
            try? await Task.sleep(for: .milliseconds(max(1000, model.settings.pollIntervalMs)))
        }
    }

    /// "13 listening ports · 2 projects · 3 apps", or "3 of 13 shown" while searching.
    private func subtitle(all: PortSections?, shown: PortSections?) -> String {
        guard let all, let shown else { return "Ports & processes" }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return "\(shown.portCount) of \(all.portCount) shown" }
        var parts = ["\(all.portCount) \(store.listeningOnly ? "listening" : "active") \(plural(all.portCount, "port"))"]
        if !all.projects.isEmpty { parts.append("\(all.projects.count) \(plural(all.projects.count, "project"))") }
        if !all.apps.isEmpty { parts.append("\(all.apps.count) \(plural(all.apps.count, "app"))") }
        return parts.joined(separator: " · ")
    }

    private func plural(_ n: Int, _ word: String) -> String { n == 1 ? word : word + "s" }

    @ViewBuilder
    private func content(_ sections: PortSections?) -> some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let sections {
            if sections.isEmpty {
                if !q.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: "No matches", message: "Nothing matches “\(q)”.")
                } else if store.listeningOnly {
                    EmptyState(symbol: "network", title: "No listening ports",
                               message: "Nothing is listening right now. Dev servers and apps that open a port will show up here.")
                } else {
                    EmptyState(symbol: "network", title: "No active ports",
                               message: "No processes are holding a network connection.")
                }
            } else {
                ScrollView {
                    PortsListView(sections: sections, searching: !q.isEmpty) { killTarget = $0 }
                        .padding(24)
                }
            }
        } else {
            PortsSkeleton().padding(24)
        }
    }
}

private struct PortsSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            bar(height: 16).frame(width: 140)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    bar(height: 28).frame(width: 180)
                    Spacer()
                    bar(height: 22).frame(width: 110)
                    bar(height: 22).frame(width: 96)
                }
                .padding(14)
                ForEach(0..<4, id: \.self) { _ in
                    Divider()
                    HStack(spacing: 12) {
                        bar(height: 14).frame(width: 52)
                        bar(height: 28).frame(maxWidth: .infinity)
                        bar(height: 14).frame(width: 190)
                        bar(height: 22).frame(width: 120)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
            .card(padding: 0)
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    private func bar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(.quaternary).frame(height: height)
    }
}
