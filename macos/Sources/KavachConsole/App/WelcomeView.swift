import KavachCore
import SwiftUI

/// First launch only (`settings.enabledModules == nil`). One screen, one
/// question. Everything this Mac supports starts ON, so Continue alone gives
/// the full app; digits toggle cards, Return continues.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var selected: [ModuleID] = ModuleID.allCases.filter(\.isAvailable)

    static let presets: [(label: String, modules: [ModuleID])] = [
        ("Everything", ModuleID.allCases),
        ("Homebrew only", [.homebrew]),
        ("Claude Chats only", [.claude]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                    Text(AppInfo.name).font(.headline).foregroundStyle(.secondary)
                }
                Text("Choose what you’ll use").font(.largeTitle.weight(.semibold))
                Text("\(AppInfo.shortName) only runs the parts you switch on. Change this any time in Settings — nothing is deleted.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(Self.presets, id: \.label) { p in
                    let available = p.modules.filter(\.isAvailable)
                    if !available.isEmpty {
                        Button(p.label) { selected = available }
                    }
                }
            }
            FeaturePicker(selection: $selected)
            HStack {
                Text("Press 1–4 to toggle, Return to continue.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Continue") {
                    model.settings.enabledModules = selected
                    model.tab = model.visibleTabs.first ?? .settings
                    model.settingsChanged()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(48)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
