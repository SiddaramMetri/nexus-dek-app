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

