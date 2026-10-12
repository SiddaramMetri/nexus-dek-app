import AppKit
import NexusCore
import SwiftUI

/// Listening ports (or every TCP connection) with their owning processes.
/// Polls on the user's interval only while the tab is shown and the window is
/// visible; refetches when the app is reactivated.
struct PortsPage: View {
    @Environment(AppModel.self) private var model

    @ViewState private var query = ""
    @ViewState private var killTarget: PortInfo?

    private var store: PortsStore { .shared }

    var body: some View {
        @Bindable var store = store
        let all = store.rows ?? []
        let filtered = Ports.filter(all, query: query)

        VStack(spacing: 0) {
            PageHeader(title: "Ports", subtitle: subtitle(total: all.count, shown: filtered.count)) {
                HStack(spacing: 8) {
                    SearchField(prompt: "Port, pid, or process…", text: $query)
                        .frame(width: 210)
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

            content(filtered)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .card(padding: 0)
                .padding(24)
        }
        .task(id: store.listeningOnly) { await poll() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.reload() }
        }
        .sheet(item: $killTarget) { PortKillSheet(target: $0) }
    }

    private func poll() async {
        while !Task.isCancelled {
            // Skip the lsof/ps shell-outs while the window is hidden to the tray.
            if NSApp.occlusionState.contains(.visible) { await store.reload() }
            try? await Task.sleep(for: .milliseconds(max(1000, model.settings.pollIntervalMs)))
        }
    }

    private func subtitle(total: Int, shown: Int) -> String {
        if store.rows == nil { return "Ports & processes" }
        if !query.isEmpty { return "\(shown) of \(total) shown" }
        return "\(total) \(store.listeningOnly ? "listening" : "active") port\(total == 1 ? "" : "s")"
    }

    @ViewBuilder
    private func content(_ filtered: [PortInfo]) -> some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        if store.rows == nil {
            PortsSkeleton()
        } else if filtered.isEmpty {
            if !q.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "No matches", message: "Nothing matches “\(q)”.")
            } else if store.listeningOnly {
                EmptyState(symbol: "network", title: "No listening ports",
                           message: "Nothing is listening right now. Apps that open a port will show up here.")
            } else {
                EmptyState(symbol: "network", title: "No active ports",
                           message: "No processes are holding a network connection.")
            }
        } else {
            PortsTable(ports: filtered) { killTarget = $0 }
        }
    }
}

/// First-load placeholder rows shaped like the table (no spinner, no jank).
private struct PortsSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { _ in
                HStack(spacing: 12) {
                    bar(height: 28).frame(maxWidth: .infinity)
                    bar(height: 14).frame(width: 56)
                    bar(height: 14).frame(width: 48)
                    bar(height: 14).frame(width: 40)
                    bar(height: 28).frame(width: 32)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                Divider()
            }
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    private func bar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(.quaternary).frame(height: height)
    }
}
