import AppKit
import KavachCore

/// Native confirm as a window-modal sheet on the main window (falls back to a
/// floating alert when the window is hidden). Every user-data mutation in
/// KavachCore requires one of these.
final class AlertConfirmer: Confirmer, @unchecked Sendable {
    @MainActor weak var window: NSWindow?

    func confirm(title: String, message: String, action: String, destructive: Bool) async -> Bool {
        await MainActor.run { () -> NSAlert in
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = destructive ? .warning : .informational
            let ok = alert.addButton(withTitle: action)
            ok.hasDestructiveAction = destructive
            alert.addButton(withTitle: "Cancel")
            return alert
        }.run(on: await MainActor.run { window })
    }
}

private extension NSAlert {
    @MainActor
    func run(on window: NSWindow?) async -> Bool {
        if let window, window.isVisible {
            return await withCheckedContinuation { cont in
                beginSheetModal(for: window) { cont.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        return runModal() == .alertFirstButtonReturn
    }
}
