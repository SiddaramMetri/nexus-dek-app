import AppKit
import NexusCore
import SwiftUI

/// Collapsible section header: chevron, title, count. The whole row toggles.
struct PortSectionHeader: View {
    let title: String
    let count: Int
    let expanded: Bool
    var trailing: String?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                Text(title).font(.headline)
                Text(String(count)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}

struct BranchChip: View {
    let branch: String

    var body: some View {
        Label(branch, systemImage: "arrow.triangle.branch")
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .foregroundStyle(.secondary)
            .help("Current git branch")
            .accessibilityLabel("Branch \(branch)")
    }
}

/// Apps: icon, name, port chips. No inline kill — Quit lives in the ⋯ menu.
struct AppPortsList: View {
    @Environment(AppModel.self) private var model
    let groups: [PortGroup]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { i, group in
                if i > 0 { Divider().padding(.leading, 46) }
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: group.key))
                        .resizable()
                        .frame(width: 22, height: 22)
                        .accessibilityHidden(true)
                    Text(group.title).font(.callout).lineLimit(1)
                    PortChips(ports: group.ports)
                    Spacer(minLength: 8)
                    menu(group)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .card(padding: 0)
    }

    private func menu(_ group: PortGroup) -> some View {
        Menu {
            Button("Quit \(group.title)…") { quit(group) }
            Divider()
            ForEach(group.ports) { port in
                Menu(":\(String(port.port)) · \(port.command) · PID \(String(port.pid))") {
                    PortContextMenu(port: port)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More for \(group.title)")
        .accessibilityLabel("More for \(group.title)")
    }

    /// Polite quit (same as ⌘Q — the app may ask to save), after a confirm.
    private func quit(_ group: PortGroup) {
        let path = URL(fileURLWithPath: group.key).standardizedFileURL.path
        let pids = Set(group.pids)
        model.perform {
            try await model.confirmer.require(
                title: "Quit \(group.title)?",
                message: "\(group.title) quits normally and frees its ports. It may ask you to save changes first.",
                action: "Quit", destructive: false)
            let running = NSWorkspace.shared.runningApplications.filter {
                $0.bundleURL?.standardizedFileURL.path == path || pids.contains($0.processIdentifier)
            }
            guard !running.isEmpty else { throw AppError.notFound("\(group.title) isn't running as an app.") }
            running.forEach { $0.terminate() }
            try? await Task.sleep(for: .seconds(1))
            await PortsStore.shared.reload()
        }
    }
}

struct PortChips: View {
    let ports: [PortInfo]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ports.prefix(6)) { PortChip(port: $0) }
            if ports.count > 6 {
                Text("+\(ports.count - 6)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// macOS components: friendly name, ports, explanatory note. Never killable.
struct SystemPortsList: View {
    let groups: [PortGroup]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { i, group in
                if i > 0 { Divider().padding(.leading, 46) }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "apple.logo").foregroundStyle(.secondary).frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(group.title).font(.callout).lineLimit(1)
                            PortChips(ports: group.ports)
                        }
                        if let note = group.subtitle {
                            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Label("Protected", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Part of macOS — Nexus Console never stops these")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .card(padding: 0)
    }
}

/// Everything else, one row per port; Homebrew services link to the Services tab.
struct OtherPortsList: View {
    @Environment(AppModel.self) private var model
    let groups: [PortGroup]
    let onStop: (PortInfo) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.port.id) { i, row in
                if i > 0 { Divider().padding(.leading, 14) }
                if let formula = row.formula {
                    PortRow(port: row.port, note: "Homebrew service · \(formula)",
                            noteAction: ("Show in Services", { model.tab = .services }), onStop: onStop)
                } else {
                    PortRow(port: row.port, onStop: onStop)
                }
            }
        }
        .card(padding: 0)
    }

    private var rows: [(port: PortInfo, formula: String?)] {
        groups.flatMap { g in g.ports.map { ($0, g.brewService) } }
    }
}
