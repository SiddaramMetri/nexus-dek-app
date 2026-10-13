import KavachCore
import SwiftUI

/// Every change the app has ever made, straight from journal.jsonl.
struct JournalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var entries: [Journal.Entry]?

    /// Journal action ids → readable labels; unknown ids show as-is (honesty
    /// beats hiding an entry that was logged).
    private static let actionLabels: [String: String] = [
        "archive": "Archived chats",
        "restore": "Restored chats",
        "delete": "Deleted archived chats",
        "setRetention": "Changed retention",
        "vscodeCleanupOrphans": "Deleted orphan VSCode caches",
        "vscodeVacuum": "VACUUMed state databases",
        "deleteNodeModules": "Deleted node_modules",
        "clearCache": "Cleared dev cache",
        "clearBrowserCache": "Cleared browser cache",
        "ollamaRm": "Deleted ollama model",
        "deletePnpmOrphanStores": "Deleted orphaned pnpm stores",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("History").font(.title3.weight(.semibold))
                Text("Every change this app has made — nothing mutates without a journal entry.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            Group {
                if let entries {
                    if entries.isEmpty {
                        Text("No changes yet — scans are read-only.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        list(entries)
                    }
                } else {
                    skeleton
                }
            }
            .frame(height: 320)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520)
        .task { entries = await DoctorFix.journal() }
    }

    private func list(_ entries: [Journal.Entry]) -> some View {
        List(entries) { e in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(Format.time(Date(timeIntervalSince1970: TimeInterval(e.tsEpoch))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.actionLabels[e.action] ?? e.action).font(.callout)
                    if !e.detail.isEmpty {
                        Text(e.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .help(e.detail)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(height: 14)
            }
            Spacer()
        }
        .padding(20)
        .accessibilityHidden(true)
    }
}
