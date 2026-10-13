import AppKit
import NexusCore
import SwiftUI

/// Small AppKit hand-offs shared by the Ports views.
enum PortActions {
    static func open(_ port: PortInfo) {
        if let url = port.localURL { NSWorkspace.shared.open(url) }
    }

    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    static func copyURL(_ port: PortInfo) {
        if let url = port.localURL { copy(url.absoluteString) }
    }

    /// VS Code's bundle, when installed.
    static var vsCodeURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")
    }

    static func openInVSCode(_ path: String) {
        guard let app = vsCodeURL else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
    }
}

/// One listening port of a killable process: `:3000  node · Next.js   uptime  cpu  mem   Open ↗  ⧉  Stop`.
/// Fixed column widths keep rows aligned across every project card.
struct PortRow: View {
    let port: PortInfo
    /// Extra caption, e.g. "Homebrew service · redis", with an optional link.
    var note: String?
    var noteAction: (label: String, run: () -> Void)?
    let onStop: (PortInfo) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(":\(String(port.port))")
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(width: 64, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(port.command).font(.callout).lineLimit(1).truncationMode(.middle)
                    if let framework = port.framework {
                        Text("· \(framework)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                caption
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(port.commandLine ?? port.command)

            PortStats(port: port)

            HStack(spacing: 4) {
                Button { PortActions.open(port) } label: {
                    Label("Open", systemImage: "arrow.up.right").labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .help("Open http://localhost:\(String(port.port)) in your browser")

                Button { PortActions.copyURL(port) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy http://localhost:\(String(port.port))")
                    .accessibilityLabel("Copy URL")

                Button("Stop", role: .destructive) { onStop(port) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(port.isSystem ? Color.secondary : Color.red)
                    .disabled(port.isSystem)
                    .help(port.isSystem ? "Cannot stop a system process" : "Stop the process (SIGTERM)")
                    .accessibilityLabel("Stop \(port.command) on port \(String(port.port))")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu { PortContextMenu(port: port, onStop: onStop) }
    }

    private var caption: some View {
        HStack(spacing: 6) {
            if let label = PortFramework.wellKnownLabel(port: port.port) { Text(label) }
            Text("PID \(String(port.pid))").monospacedDigit()
            if let note {
                Text("·")
                Text(note)
                if let noteAction {
                    Button(noteAction.label, action: noteAction.run).buttonStyle(.link)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// Uptime · CPU · memory, fixed-width so columns line up.
struct PortStats: View {
    let port: PortInfo

    var body: some View {
        HStack(spacing: 10) {
            stat(Format.duration(port.uptimeSecs), symbol: "clock", help: "Uptime").frame(width: 70, alignment: .trailing)
            stat(Format.percent(port.cpu), symbol: "cpu", help: "CPU").frame(width: 58, alignment: .trailing)
            stat(Format.bytes(port.memoryBytes), symbol: "memorychip", help: "Memory").frame(width: 70, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func stat(_ value: String, symbol: String, help: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).imageScale(.small).foregroundStyle(.tertiary)
            Text(value).lineLimit(1)
        }
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(help) \(value)")
    }
}

/// Right-click / ⋯ details for one port.
struct PortContextMenu: View {
    let port: PortInfo
    var onStop: ((PortInfo) -> Void)?

    var body: some View {
        Button("Open in browser") { PortActions.open(port) }
        Button("Copy URL") { PortActions.copyURL(port) }
        Button("Copy PID") { PortActions.copy(String(port.pid)) }
        if let cmd = port.commandLine, !cmd.isEmpty {
            Button("Copy command") { PortActions.copy(cmd) }
        }
        if let onStop, !port.isSystem {
            Divider()
            Button("Stop \(port.command)…", role: .destructive) { onStop(port) }
        }
    }
}

/// `:11434` capsule; hover shows the owning process.
struct PortChip: View {
    let port: PortInfo

    var body: some View {
        Text(":\(String(port.port))")
            .font(.caption.monospacedDigit().weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .help(chipHelp)
    }

    private var chipHelp: String {
        var parts = [port.command, "PID \(String(port.pid))"]
        if let label = PortFramework.wellKnownLabel(port: port.port) { parts.insert(label, at: 0) }
        return parts.joined(separator: " · ")
    }
}
