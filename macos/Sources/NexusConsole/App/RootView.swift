import AppKit
import NexusCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.needsOnboarding {
                WelcomeView()
            } else {
                MainView()
            }
        }
        .frame(minWidth: 1000, minHeight: 660)
        .overlay(alignment: .bottomTrailing) { ToastStack() }
        .overlay(alignment: .bottomLeading) { ActivityBar().animation(.snappy, value: model.activities.count) }
        .onAppear { applyTheme(model.settings.theme) }
        .onChange(of: model.settings.theme) { _, t in applyTheme(t) }
    }

    private func applyTheme(_ t: ThemeMode) {
        NSApp.appearance = switch t {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: Binding($model.tab)) {
                ForEach(model.visibleTabs.filter { $0 != .settings }) { tab in
                    SidebarRow(tab: tab).tag(tab)
                }
                Section {
                    SidebarRow(tab: .settings).tag(Tab.settings)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    ThemeToggle(showsLabel: true)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            VStack(spacing: 0) {
                page(for: model.tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if model.terminals.drawerOpen {
                    Divider()
                    TerminalDrawer().frame(height: model.terminals.drawerHeight)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .background { tabShortcuts }
        }
        .onChange(of: model.tab) { _, _ in Task { await model.refreshServices() } }
        .onChange(of: model.visibleTabs) { _, tabs in
            if !tabs.contains(model.tab), let first = tabs.first { model.tab = first }
        }
    }

    /// ⌘1…⌘9 jump to the visible tabs in sidebar order.
    private var tabShortcuts: some View {
        ForEach(Array(model.visibleTabs.prefix(9).enumerated()), id: \.element) { i, tab in
            Button("") { model.tab = tab }
                .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func page(for tab: Tab) -> some View {
        switch tab {
        case .services: ServicesPage()
        case .packages: PackagesPage()
        case .sessions: SessionsPage()
        case .ports: PortsPage()
        case .doctor: DoctorPage()
        case .archiver: ArchiverPage()
        case .settings: SettingsPage()
        }
    }
}

private extension Binding where Value == Tab {
    /// List selection wants an Optional; never let it deselect to nil.
    init(_ source: Binding<Tab>) { self = source }
}

private extension List where SelectionValue == Tab {
    init(selection: Binding<Tab>, @ViewBuilder content: () -> Content) {
        self.init(selection: Binding<Tab?>(get: { selection.wrappedValue }, set: { if let v = $0 { selection.wrappedValue = v } }),
                  content: content)
    }
}

struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    let tab: Tab

    var body: some View {
        HStack {
            Label(tab.label, systemImage: tab.symbol)
            Spacer()
            if tab == .services, !model.trayTitle.isEmpty {
                Text(model.trayTitle).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}
