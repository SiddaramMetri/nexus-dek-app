import KavachCore
import SwiftUI

struct GuardPage: View {
    @Environment(AppModel.self) private var model

    private var guardModel: GuardModel { model.guardian }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Guard", subtitle: "Lock your screen when you step away · keep your Mac awake for long builds")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        LockCard(guardModel: guardModel)
                        AwakeCard(guardModel: guardModel)
                    }
                    GeneralCard(guardModel: guardModel)
                }
                .padding(24)
                .frame(maxWidth: 1100, alignment: .leading)
            }
        }
        // Permission changes happen in System Settings; pick them up while visible.
        .task {
            while !Task.isCancelled {
                guardModel.refreshPermissions()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct LockCard: View {
    @Bindable var guardModel: GuardModel

    var body: some View {
        GuardSection("Lock screen", symbol: "lock.shield",
                     note: "Blocks the keyboard and covers every display until you unlock with Touch ID or your Mac password. Apps keep running behind it.") {
            HStack(spacing: 12) {
                Button { guardModel.lock() } label: {
                    Label("Lock now", systemImage: "lock.fill").frame(minWidth: 96)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                if guardModel.settings.lockShortcut != .off {
                    Text("or press \(guardModel.settings.lockShortcut.label)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            permission
            Divider()
            GuardRow("Shortcut", "Works from any app.") {
                Picker("Shortcut", selection: $guardModel.settings.lockShortcut) {
                    ForEach(LockShortcut.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 110)
            }
            GuardRow("Block trackpad gestures", "Stops swipes to other Spaces and Mission Control while locked.") {
                Toggle("Block trackpad gestures", isOn: $guardModel.settings.blockGestures).toggleStyle(.switch).labelsHidden()
            }
            GuardRow("Unlock with", ScreenLocker.touchIDAvailable ? "Touch ID, or your Mac password." : "Your Mac password (no Touch ID found).") {
                Image(systemName: ScreenLocker.touchIDAvailable ? "touchid" : "key.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    @ViewBuilder
    private var permission: some View {
        if guardModel.hasAccessibility {
            Label("Accessibility allowed", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Needs Accessibility to block the keyboard", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                Text("Without it the lock can't stop keys reaching the apps behind it, so \(AppInfo.shortName) won't lock at all. Turn on \(AppInfo.name) in the list, then come back. After installing a new build you may need to turn it off and on again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Accessibility Settings…") { guardModel.openAccessibilitySettings() }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct AwakeCard: View {
    @Bindable var guardModel: GuardModel

    var body: some View {
        GuardSection("Keep awake", symbol: "cup.and.heat.waves",
                     note: "Stops idle sleep during long builds, downloads and deploys. Keeps running behind the lock. Closing the lid still sleeps.") {
            HStack(spacing: 12) {
                status
                Spacer()
                Button {
                    guardModel.toggleAwake()
                } label: {
                    Label(guardModel.isAwake ? "Stop" : "Start", systemImage: guardModel.isAwake ? "stop.fill" : "play.fill")
                        .frame(minWidth: 72)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(guardModel.isAwake ? .orange : .accentColor)
            }
            Divider()
            GuardRow("Duration", "How long each session lasts.") {
                Picker("Duration", selection: $guardModel.settings.awakeMinutes) {
                    ForEach(KeepAwakePolicy.durations, id: \.self) { Text(KeepAwakePolicy.label(minutes: $0)).tag($0) }
                }
                .labelsHidden().frame(width: 150)
            }
            GuardRow("Also keep the display on", "Otherwise the screen dims and sleeps as usual.") {
                Toggle("Keep display on", isOn: $guardModel.settings.keepDisplayOn).toggleStyle(.switch).labelsHidden()
            }
            GuardRow("Low battery cutoff", "On battery, stop at this level so the Mac can sleep.") {
                Picker("Low battery cutoff", selection: $guardModel.settings.batteryCutoff) {
                    ForEach(KeepAwakePolicy.cutoffs, id: \.self) { Text($0 == 0 ? "Never" : "\($0)%").tag($0) }
                }
                .labelsHidden().frame(width: 90)
            }
            GuardRow("Start when \(AppInfo.shortName) opens", "Begins a session with the duration above.") {
                Toggle("Start on launch", isOn: $guardModel.settings.awakeOnLaunch).toggleStyle(.switch).labelsHidden()
            }
        }
    }

    private var status: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 2) {
                Text(guardModel.isAwake ? "On" : "Off")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(guardModel.isAwake ? Color.green : .secondary)
                Text(guardModel.isAwake
                    ? (guardModel.awakeUntil.map { KeepAwakePolicy.remaining(until: $0).capitalizedFirst } ?? "Until you turn it off")
                    : "Your Mac sleeps normally")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct GeneralCard: View {
    @Bindable var guardModel: GuardModel

    var body: some View {
        GuardSection("General", symbol: "gearshape") {
            GuardRow("Launch at login", "Keeps the shortcut and menu bar ready after a restart.") {
                Toggle("Launch at login", isOn: Binding(get: { guardModel.launchAtLogin },
                                                        set: { guardModel.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch).labelsHidden()
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Label("Good to know", systemImage: "info.circle").font(.callout.weight(.medium))
                Text("Guard is a hands-off lock for short breaks, not a replacement for the macOS lock screen. When you leave your Mac somewhere public, use Apple menu ▸ Lock Screen (⌃⌘Q).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text("Inspired by").font(.caption).foregroundStyle(.secondary)
                    Link("Locksee by tejaskh3", destination: URL(string: "https://github.com/tejaskh3/Locksee")!).font(.caption)
                }
            }
        }
    }
}

// MARK: - Layout helpers

private struct GuardSection<Content: View>: View {
    let title: String
    let symbol: String
    let note: String?
    let content: Content

    init(_ title: String, symbol: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: symbol).font(.headline)
                if let note {
                    Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card(padding: 16)
    }
}

private struct GuardRow<Control: View>: View {
    let title: String
    let detail: String
    let control: Control

    init(_ title: String, _ detail: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
