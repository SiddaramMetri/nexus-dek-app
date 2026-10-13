import KavachCore
import SwiftUI

/// All archive knobs in one place: tray automation + Claude's retention.
struct ArchiveSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Archive settings").font(.title3.weight(.semibold))
                Text("Automation runs while the app sits in the tray — no restart needed.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ArchiveAutomationSettings()
            Divider()
            ArchiveRetentionControl()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// Tray automation toggles — the scheduler reads these live from the settings
/// store every tick, so changes apply without a restart.
struct ArchiveAutomationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            setting("Auto-archive daily", "Moves chats older than the cutoff to the archive.") {
                Toggle("Auto-archive daily", isOn: $model.settings.autoArchiveEnabled)
            }
            if model.settings.autoArchiveEnabled {
                HStack {
                    Text("Older than").foregroundStyle(.secondary)
                    Spacer()
                    Picker("Auto-archive cutoff", selection: $model.settings.autoArchiveCutoffDays) {
                        ForEach([7, 14, 30, 90], id: \.self) { Text("\($0)d").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            setting("Auto-VACUUM VSCode", "Compacts bloated databases whenever VSCode is closed.") {
                Toggle("Auto-VACUUM VSCode", isOn: $model.settings.autoVacuumEnabled)
            }
        }
    }

    private func setting<C: View>(_ title: String, _ note: String, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            control().toggleStyle(.switch).labelsHidden()
        }
    }
}

/// Claude Code's `cleanupPeriodDays` — the silent-deletion setting (default 30).
/// Saving goes through KavachCore's confirm + parse-modify-write with a .bak.
struct ArchiveRetentionControl: View {
    /// Below this, restored chats can be silently deleted again soon.
    static let warnDays = 90

    @Environment(AppModel.self) private var model
    @ViewState private var settings: ClaudeSettings?
    @ViewState private var draft: String?
    @ViewState private var saving = false

    var body: some View {
        let current = settings?.cleanupPeriodDays
        let value = draft ?? current.map(String.init) ?? ""
        let parsed = Int(value.trimmingCharacters(in: .whitespaces))
        let valid = (parsed ?? 0) > 0
        let low = (draft == nil ? (current ?? 30) : (parsed ?? 0)) < Self.warnDays
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Keep chats").font(.body.weight(.medium))
                Text("Claude deletes older transcripts — archived ones are safe.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if settings == nil {
                Text("30 days · Save").redacted(reason: .placeholder)
            } else {
                if low {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Below \(Self.warnDays) days, restored chats can be silently deleted again")
                        .accessibilityLabel("Below \(Self.warnDays) days, restored chats can be silently deleted again")
                }
                TextField("Days", text: Binding(get: { value }, set: { draft = $0 }))
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 64)
                    .labelsHidden()
                    .onSubmit { if valid, draft != nil, parsed != current { save(parsed ?? 0) } }
                Text("days").foregroundStyle(.secondary)
                Button("Save") { save(parsed ?? 0) }
                    .disabled(!valid || draft == nil || parsed == current || saving)
            }
        }
        .help("Claude Code silently deletes chats older than this (its default is 30 days). Archived chats are "
            + "outside its reach, but restored ones re-expire.")
        .task { await load() }
    }

    private func load() async {
        do { settings = try await ClaudeArchiver.settings() } catch { model.report(error) }
    }

    private func save(_ days: Int) {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await ClaudeArchiver.setRetention(days: days, confirmer: model.confirmer)
                draft = nil
                model.toast("Chat retention set to \(days) days")
            } catch {
                model.report(error)
            }
            await load()
        }
    }
}
