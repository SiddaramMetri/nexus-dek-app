import AppKit
import KavachCore

/// Menu-bar item: monochrome template glyph + "running/total" count, and a
/// menu listing active services (checkmark = running; rows are read-only).
@MainActor
final class StatusBar: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private let showWindow: () -> Void

    private let diskItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// What the "Dev servers" section last showed — rebuild only on change.
    private var serversSignature = ""
    private var serversTask: Task<Void, Never>?

    init(model: AppModel, showWindow: @escaping () -> Void) {
        self.model = model
        self.showWindow = showWindow
        super.init()
        let image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "\(AppInfo.name)")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.imagePosition = .imageLeading
        refresh()
        watchServers()
    }

    // MARK: - Dev servers

    struct DevServer {
        let project: String
        let slot: ServerSlot
        let port: PortInfo
    }

    /// Running servers in the user's projects, from the Ports snapshot.
    private var devServers: [DevServer] {
        guard model.settings.isEnabled(.ports), let snap = PortsStore.shared.snapshot else { return [] }
        return PortSections.build(snap).projects.flatMap { g in
            g.servers.compactMap { slot in slot.running.first.map { DevServer(project: g.title, slot: slot, port: $0) } }
        }
    }

    /// Keeps the snapshot warm (cheap: one lsof + one ps + one lsof, every
    /// 15s) so the menu is current the moment it opens.
    private func watchServers() {
        serversTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.model.settings.isEnabled(.ports) {
                    await PortsStore.shared.reload()
                    let sig = self.devServers.map { "\($0.project):\($0.port.port):\($0.port.pid)" }.joined(separator: "|")
                    if sig != self.serversSignature {
                        self.serversSignature = sig
                        self.refresh()
                    }
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func addDevServers(to menu: NSMenu) {
        let servers = devServers
        menu.addItem(disabled("Dev servers"))
        if servers.isEmpty {
            menu.addItem(disabled("No dev servers running"))
        }
        for s in servers {
            let title = "\(s.project) · \(s.slot.role.label) · :\(s.port.port)"
            let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            row.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Running")?
                .withSymbolConfiguration(.init(pointSize: 7, weight: .regular).applying(.init(paletteColors: [.systemGreen])))
            let sub = NSMenu()
            sub.addItem(action("Open http://localhost:\(s.port.port)", #selector(openServer(_:)), s.port))
            sub.addItem(action("Copy URL", #selector(copyServer(_:)), s.port))
            sub.addItem(.separator())
            sub.addItem(action("Stop \(s.slot.name)…", #selector(stopServer(_:)), (s.port, s.slot.name, s.project)))
            row.submenu = sub
            menu.addItem(row)
        }
        let ports = NSMenuItem(title: "Open Ports…", action: #selector(openPorts), keyEquivalent: "")
        ports.target = self
        menu.addItem(ports)
        menu.addItem(.separator())
    }

    private func action(_ title: String, _ sel: Selector, _ payload: Any) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        i.representedObject = payload
        return i
    }

    @objc private func openServer(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? PortInfo { PortActions.open(p) }
    }

    @objc private func copyServer(_ sender: NSMenuItem) {
        if let p = sender.representedObject as? PortInfo { PortActions.copyURL(p) }
    }

    @objc private func openPorts() {
        model.tab = .ports
        showWindow()
    }

    /// Native confirm, then SIGTERM — same guards as the Ports tab.
    @objc private func stopServer(_ sender: NSMenuItem) {
        guard let (port, name, project) = sender.representedObject as? (PortInfo, String, String) else { return }
        let model = model
        if port.launchdJob?.isUserAgent == true {
            LaunchdPrompt.stop(port, name: name, projectRoot: nil, model: model) { _ in }
            return
        }
        Task {
            let ok = await model.confirmer.confirm(
                title: "Stop \(name) in \(project)?",
                message: "Sends a normal stop signal to PID \(port.pid) on port \(port.port). Unsaved work in that server may be lost.",
                action: "Stop", destructive: true)
            guard ok else { return }
            do {
                try await Ports.kill(pid: port.pid, force: false, sudo: false)
                model.toast("Stopped \(name) in \(project)")
                await PortsStore.shared.reload()
                self.refresh()
            } catch {
                model.report(error)
            }
        }
    }

    func refresh() {
        item.button?.title = model.trayTitle.isEmpty ? "" : " \(model.trayTitle)"
        let menu = NSMenu()
        menu.delegate = self
        diskItem.isEnabled = false
        updateDisk()
        // One item, reused: it must leave the old menu before joining the new one.
        diskItem.menu?.removeItem(diskItem)
        menu.addItem(diskItem)
        if model.settings.isEnabled(.doctor) {
            let clean = NSMenuItem(title: "Free up space…", action: #selector(openCleanup), keyEquivalent: "")
            clean.target = self
            menu.addItem(clean)
        }
        menu.addItem(.separator())
        if model.settings.isEnabled(.ports) { addDevServers(to: menu) }
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
        menu.addItem(NSMenuItem(title: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    @objc private func openDashboard() { showWindow() }

    @objc private func openCleanup() {
        model.tab = .cleanup
        showWindow()
    }

    /// Fresh disk number every time the menu opens; servers refresh in the
    /// background so the next open is current too.
    func menuWillOpen(_ menu: NSMenu) {
        updateDisk()
        Task {
            await PortsStore.shared.reload()
            let sig = devServers.map { "\($0.project):\($0.port.port):\($0.port.pid)" }.joined(separator: "|")
            if sig != serversSignature { serversSignature = sig; refresh() }
        }
    }

    private func updateDisk() {
        guard let d = DiskSpace.current() else { diskItem.title = "Free disk space: unknown"; return }
        let low = d.free < DiskSpace.lowThreshold
        diskItem.title = "\(low ? "⚠︎ " : "")Free disk: \(Format.bytes(d.free)) of \(Format.bytes(d.total))"
    }
}
