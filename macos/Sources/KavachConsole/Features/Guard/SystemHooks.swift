import Carbon.HIToolbox
import IOKit.pwr_mgt
import KavachCore
import ServiceManagement

/// IOKit power assertions: idle system sleep (and optionally display sleep)
/// is blocked while held. Released on deinit, so a quit always lets the Mac sleep.
@MainActor
final class PowerAssertions {
    private var ids: [IOPMAssertionID] = []

    var isHeld: Bool { !ids.isEmpty }

    func hold(display: Bool) {
        release()
        var types = [kIOPMAssertPreventUserIdleSystemSleep]
        if display { types.append(kIOPMAssertPreventUserIdleDisplaySleep) }
        for type in types {
            var id: IOPMAssertionID = 0
            let reason = "\(AppInfo.name): keep awake" as CFString
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess {
                ids.append(id)
            }
        }
    }

    func release() {
        ids.forEach { IOPMAssertionRelease($0) }
        ids = []
    }

    deinit { ids.forEach { IOPMAssertionRelease($0) } }
}

/// One system-wide hotkey through Carbon's RegisterEventHotKey — works without
/// any permission, and only fires for the exact combo (it never sees other keys).
@MainActor
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: () -> Void = {}

    func set(_ shortcut: LockShortcut, action: @escaping () -> Void) {
        clear()
        guard let keyCode = shortcut.keyCode else { return }
        self.action = action
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
                guard let userData else { return noErr }
                let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { me.action() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let id = EventHotKeyID(signature: 0x4B56_4C4B /* KVLK */, id: 1)
        RegisterEventHotKey(keyCode, shortcut.carbonModifiers, id, GetEventDispatcherTarget(), 0, &ref)
    }

    func clear() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

/// Launch at login through SMAppService (shows under Login Items in System Settings).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
