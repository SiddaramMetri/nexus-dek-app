import NexusCore
import SwiftUI

extension PortInfo {
    /// Non-optional sort keys: rows without a ps sample sort first ascending.
    var cpuSortKey: Double { cpu ?? -1 }
    var memorySortKey: UInt64 { memoryBytes ?? 0 }
}

/// Sortable ports table; the trailing trash button opens the kill sheet.
struct PortsTable: View {
    let ports: [PortInfo]
    let onKill: (PortInfo) -> Void

    @ViewState private var sortOrder: [KeyPathComparator<PortInfo>] = []

    private var rows: [PortInfo] { sortOrder.isEmpty ? ports : ports.sorted(using: sortOrder) }

    var body: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("Process", value: \.command) { p in
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.command).font(.callout).lineLimit(1).truncationMode(.middle)
                    Text(p.user).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 3)
                .help(p.command)
            }
            .width(min: 160, ideal: 240)

            TableColumn("Port", value: \.port) { p in
                Text(":\(String(p.port))")
                    .font(.callout.monospacedDigit().weight(.medium))
                    .trailingAligned()
            }
            .width(min: 60, ideal: 80, max: 110)

            TableColumn("PID", value: \.pid) { p in
                Text(String(p.pid)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).trailingAligned()
            }
            .width(min: 56, ideal: 72, max: 100)

            TableColumn("CPU", value: \.cpuSortKey) { p in
                Text(Format.percent(p.cpu)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).trailingAligned()
            }
            .width(min: 56, ideal: 68, max: 100)

            TableColumn("Mem", value: \.memorySortKey) { p in
                Text(Format.bytes(p.memoryBytes)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .trailingAligned()
            }
            .width(min: 60, ideal: 80, max: 110)

            TableColumn("") { p in
                Button { onKill(p) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(p.isSystem ? Color.secondary : Color.red)
                    .disabled(p.isSystem)
                    .help(p.isSystem ? "Cannot kill a system process" : "Kill process")
                    .accessibilityLabel("Kill \(p.command)")
                    .trailingAligned()
            }
            .width(min: 36, ideal: 44, max: 52)
        }
    }
}

private extension View {
    func trailingAligned() -> some View { frame(maxWidth: .infinity, alignment: .trailing) }
}
