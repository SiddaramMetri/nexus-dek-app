import AppKit
import KavachCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var window: NSWindow!
    private var statusBar: StatusBar!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        window = makeWindow()
        model.confirmer.window = window
        statusBar = StatusBar(model: model, showWindow: { [weak self] in self?.showWindow() })
        model.onTrayChange = { [weak self] in self?.statusBar.refresh() }
        model.guardian.onChange = { [weak self] in self?.statusBar.refresh() }
        model.guardian.onLockRefused = { [weak self] in
            self?.model.tab = .guardian
            self?.showWindow()
        }
        model.start()
        DistributedNotificationCenter.default().addObserver(
            forName: showNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.showWindow() } }
        showWindow()
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "\(AppInfo.name)"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.minSize = NSSize(width: 1000, height: 660)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: RootView().environment(model))
        // Restores size/position across launches.
        if !w.setFrameUsingName("KavachMain") { w.center() }
        w.setFrameAutosaveName("KavachMain")
        return w
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The close button hides to the menu bar — services keep running.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Real quit: kill PTYs, stop services this app started ephemerally.
    func applicationWillTerminate(_ notification: Notification) {
        model.terminals.killAll()
        if model.settings.quitBehavior == .stopUnlinked {
            model.services.stopEphemeral()
        }
    }

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(AppInfo.name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(AppInfo.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenuItem(title: "Find", action: #selector(focusSearch), keyEquivalent: "f")
        find.target = self
        edit.addItem(find)
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        let terminal = NSMenuItem(title: "Toggle Terminal", action: #selector(toggleTerminal), keyEquivalent: "`")
        terminal.keyEquivalentModifierMask = [.control]
        terminal.target = self
        view.addItem(terminal)
        let theme = NSMenuItem(title: "Toggle Light/Dark Mode", action: #selector(toggleTheme), keyEquivalent: "l")
        theme.keyEquivalentModifierMask = [.command, .shift]
        theme.target = self
        view.addItem(theme)
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    @objc private func openSettings() {
        model.tab = .settings
        showWindow()
    }

    /// Focuses the visible page's search field (no-op on pages without one).
    @objc private func focusSearch() {
        model.searchFocusToken += 1
    }

    @objc private func toggleTheme() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        model.toggleTheme(currentlyDark: dark)
    }

    @objc private func toggleTerminal() {
        model.terminals.toggleDrawer()
    }
}
