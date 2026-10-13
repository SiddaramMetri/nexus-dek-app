import KavachCore
import SwiftUI

struct SettingsPage: View {
    @Environment(AppModel.self) private var model
    @ViewState private var addOpen = false
    @ViewState private var updating = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            PageHeader(title: "Settings", subtitle: "Features, theme, Homebrew & managed services")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("Features", note: "Turning a feature off stops its background work right away. Your data stays — managed services, archives and history are untouched.") {
                        FeaturePicker(selection: Binding(
                            get: { model.settings.enabledModules ?? ModuleID.allCases },
                            set: { model.settings.enabledModules = $0; model.settingsChanged() }))
                    }
                    HStack(alignment: .top, spacing: 16) {
                        section("Appearance") { appearance }
                        section("Homebrew") { homebrew }
                    }
                    if model.settings.isEnabled(.homebrew) {
                        section("Managed services", note: "Services \(AppInfo.shortName) keeps in view, even when they're stopped.",
                                trailing: AnyView(Button { addOpen = true } label: { Label("Add service", systemImage: "plus") })) {
                            managed
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 1100, alignment: .leading)
            }
        }
        .sheet(isPresented: $addOpen) { AddServiceSheet() }
    }

    private var appearance: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 14) {
            row("Theme", "Match your system, or force light/dark.") {
                Picker("Theme", selection: $model.settings.theme) {
                    Text("System").tag(ThemeMode.system)
                    Text("Light").tag(ThemeMode.light)
                    Text("Dark").tag(ThemeMode.dark)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }
            row("Default layout", "How services are shown on the Services tab.") {
                Picker("Layout", selection: $model.settings.layout) {
                    Text("Grid").tag(CardLayout.grid)
                    Text("List").tag(CardLayout.list)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 130)
            }
            row("On quit", "Services started without Link are stopped when you quit.") {
                Picker("On quit", selection: $model.settings.quitBehavior) {
                    Text("Stop unlinked").tag(QuitBehavior.stopUnlinked)
                    Text("Keep all").tag(QuitBehavior.keepAll)
                }
                .labelsHidden().frame(width: 150)
            }
            row("Low disk warning", "Notify when your Mac has under 10 GB free.") {
                Toggle("Low disk warning", isOn: $model.settings.lowDiskWarning).toggleStyle(.switch).labelsHidden()
            }
            row("Refresh every", "How often Homebrew is polled while \(AppInfo.shortName) runs.") {
                Picker("Refresh", selection: Binding(get: { model.settings.pollIntervalMs },
                                                     set: { model.settings.pollIntervalMs = $0; model.settingsChanged() })) {
                    Text("2 s").tag(2000)
                    Text("4 s").tag(4000)
                    Text("10 s").tag(10000)
                    Text("30 s").tag(30000)
                }
                .labelsHidden().frame(width: 90)
            }
        }
    }

    @ViewBuilder
    private var homebrew: some View {
        let detected = model.context.brewPrefix != nil
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(detected ? "Installed · v\(model.brewVersion ?? "—")" : "Homebrew not detected",
                      systemImage: detected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(detected ? Color.green : Color.orange)
                Spacer()
                if detected {
                    Button {
                        updating = true
                        model.perform("Homebrew updated") {
                            defer { updating = false }
                            try await model.track(brew: true, "Updating Homebrew") { try await model.brew.mutate(["update"]) }
                        }
                    } label: {
                        if updating { ProgressView().controlSize(.small) } else { Label("Update Homebrew", systemImage: "arrow.clockwise") }
                    }
                    .disabled(updating)
                }
            }
            if detected {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { Text("Prefix").foregroundStyle(.secondary); Text(model.context.brewPrefix ?? "").font(.callout.monospaced()).textSelection(.enabled) }
                    GridRow { Text("Platform").foregroundStyle(.secondary); Text("macos · \(model.context.arch)").font(.callout.monospaced()) }
                }
                .font(.callout)
            } else {
                Text("Install it from brew.sh, then reopen \(AppInfo.name).").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var managed: some View {
        if model.intent.managed.isEmpty {
            Text("No managed services yet. Add one to pin it here.").font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(model.intent.managed, id: \.formula) { m in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.displayName)
                            Text(m.formula).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { model.removeManaged(m.formula) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Remove \(m.displayName)")
                    }
                    .padding(.vertical, 7)
                    if m != model.intent.managed.last { Divider() }
                }
            }
        }
    }

    private func section<C: View>(_ title: String, note: String? = nil, trailing: AnyView? = nil,
                                  @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    if let note { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer()
                trailing
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card(padding: 16)
    }

    private func row<C: View>(_ title: String, _ detail: String, @ViewBuilder control: () -> C) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            control()
        }
    }
}
