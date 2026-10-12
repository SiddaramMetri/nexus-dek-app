import AppKit
import NexusCore

/// Menu-bar item: monochrome template glyph + "running/total" count, and a
/// menu listing active services (checkmark = running; rows are read-only).
@MainActor
final class StatusBar: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private let showWindow: () -> Void

    init(model: AppModel, showWindow: @escaping () -> Void) {
        self.model = model
        self.showWindow = showWindow
        super.init()
        let image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Nexus Console")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.imagePosition = .imageLeading
        refresh()
    }

    func refresh() {
        item.button?.title = model.trayTitle.isEmpty ? "" : " \(model.trayTitle)"
        let menu = NSMenu()
        if model.settings.isEnabled(.homebrew) {
            menu.addItem(disabled("Active Services"))
            if model.trayServices.isEmpty {
                menu.addItem(disabled("No active services"))
            } else {
                for s in model.trayServices {
                    let row = disabled(s.name)
                    row.state = s.running ? .on : .off
                    menu.addItem(row)
                }
            }
            menu.addItem(.separator())
        }
        let open = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Nexus Console", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func openDashboard() { showWindow() }
}
