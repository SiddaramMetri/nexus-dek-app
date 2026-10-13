import AppKit
import KavachCore
import SwiftUI

/// Everything Homebrew installed. The installed list (fast `brew list`) renders
/// first; outdated badges and "Upgrade all" merge in when the slow
/// `brew outdated` lands, without reflowing the table.
struct PackagesPage: View {
    @Environment(AppModel.self) private var model

    @ViewState private var query = ""
    @ViewState private var filter: PackageFilter = .all
    @ViewState private var selection: PackageItem.ID?
    @ViewState private var uninstallTarget: PackageItem?

    private var store: PackagesStore { .shared }
    private var backend: PackagesBackend { PackagesBackend(brew: model.brew) }

    var body: some View {
        if model.context.brewBin == nil {
            EmptyState(symbol: "shippingbox", title: "Homebrew not detected",
                       message: "Install Homebrew from brew.sh, then reopen \(AppInfo.name) to manage packages.")
        } else {
            page
        }
    }

    private var page: some View {
        let packages = store.packages
        let visible = PackagesBackend.filter(packages, query: query, filter: filter)
        let selected = selection.flatMap { id in packages.first { $0.id == id } }

        return VStack(spacing: 0) {
            PageHeader(title: "Packages", subtitle: subtitle) {
                PackagesToolbar(
                    query: $query, filter: $filter,
                    upgradeableCount: PackagesBackend.upgradeableCount(packages),
                    isUpgradingAll: store.isUpgradingAll,
                    isFetching: store.isFetching,
                    onUpgradeAll: { store.upgradeAll(count: PackagesBackend.upgradeableCount(packages), model: model) },
                    onRefresh: { Task { await store.reloadList(backend) } })
            }
            .padding(.bottom, 8)
            Divider()

            HStack(spacing: 0) {
                main(visible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let selected {
                    Divider()
                    PackageInfoPanel(name: selected.name) { selection = nil }
                        .frame(width: 300)
                        .id(selected.id)
                }
            }
        }
        .task { store.refreshIfStale(backend) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshIfStale(backend)
        }
        .sheet(item: $uninstallTarget) { p in PackageUninstallSheet(name: p.name) }
    }

    private var subtitle: String {
        store.isCheckingOutdated && store.installed != nil
            ? "Everything Homebrew installed · checking for updates…"
            : "Everything Homebrew installed"
    }

    @ViewBuilder
    private func main(_ visible: [PackageItem]) -> some View {
        if let error = store.listError {
            VStack {
                ErrorPanel(error: error,
                           retry: { Task { await store.reloadList(backend) } },
                           trustTap: { store.trustTap($0, model: model) })
                Spacer()
            }
            .padding(24)
        } else if store.isPending {
            ProgressView().controlSize(.small)
        } else {
            PackagesTable(
                packages: visible,
                selection: $selection,
                serviceNames: Set(model.brewServices.map(\.name)),
                upgrading: store.upgrading,
                onUpgrade: { store.upgrade($0.name, model: model) },
                onAddToServices: { p in
                    model.addManaged(p.name)
                    model.toast("Added \(Format.formulaDisplayName(p.name)) to Services")
                },
                onUninstall: { uninstallTarget = $0 })
        }
    }
}

/// Search · filter · upgrade all · refresh. "Upgrade all" sits leftmost so
/// its arrival (after the outdated check) never shifts the other controls.
private struct PackagesToolbar: View {
    @Binding var query: String
    @Binding var filter: PackageFilter
    let upgradeableCount: Int
    let isUpgradingAll: Bool
    let isFetching: Bool
    let onUpgradeAll: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if upgradeableCount > 0 {
                Button(action: onUpgradeAll) {
                    HStack(spacing: 5) {
                        if isUpgradingAll {
                            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.up.circle")
                        }
                        Text("Upgrade all (\(upgradeableCount))")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isUpgradingAll)
            }
            SearchField(prompt: "Search packages…", text: $query)
                .frame(width: 210)
            Picker("Filter", selection: $filter) {
                ForEach(PackageFilter.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            FetchRefreshButton(isFetching: isFetching, action: onRefresh)
        }
    }
}

/// Refresh button whose icon becomes a spinner while a fetch is in flight
/// (fixed size, so the swap never shifts neighbours).
struct FetchRefreshButton: View {
    let isFetching: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                ZStack {
                    if isFetching {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 14, height: 14)
                Text("Refresh")
            }
        }
        .keyboardShortcut("r", modifiers: .command)
        .help("Refresh (⌘R)")
    }
}
