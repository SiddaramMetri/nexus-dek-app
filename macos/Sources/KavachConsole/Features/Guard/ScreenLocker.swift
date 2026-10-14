import AppKit
import KavachCore
@preconcurrency import LocalAuthentication
import SwiftUI

/// "Hands off" lock: a shield window over every display, plus a session event
/// tap that swallows the keyboard (and optionally trackpad gestures) so nothing
/// behind the shield can be reached. Unlock with Touch ID or the Mac password.
///
/// Fails closed: without the Accessibility permission the tap can't be
/// installed, so it refuses to lock rather than show a shield that leaks input.
/// It is not a security boundary — the macOS lock screen (⌃⌘Q) is.
@MainActor @Observable
final class ScreenLocker {
    enum Phase: Equatable { case idle, touchID, password, checking }

    private(set) var isLocked = false
    var phase: Phase = .idle
    var password = ""
    var message: String?
    /// Bumped on a wrong password so the field can shake.
    private(set) var wrongCount = 0
    private(set) var authContext: LAContext?
    var onUnlock: () -> Void = {}

    @ObservationIgnored private var windows: [NSWindow] = []
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var tapSource: CFRunLoopSource?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var lastKey = Date()
    @ObservationIgnored private var standingDown = false
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var content: (Bool) -> AnyView = { _ in AnyView(EmptyView()) }

    static func hasAccessibility(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static var touchIDAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// Locks now. Returns nil on success, otherwise why it couldn't.
    /// `content(isPrimary)` builds the view for each display.
    func lock(blockGestures: Bool, content: @escaping (Bool) -> AnyView) -> String? {
        guard !isLocked else { return nil }
        guard Self.hasAccessibility(prompt: true) else {
            return "Allow \(AppInfo.name) under Privacy & Security ▸ Accessibility, then lock again."
        }
        guard installTap(blockGestures: blockGestures) else {
            return "macOS didn't let \(AppInfo.name) guard the keyboard, so the screen wasn't locked. Re-allow it under Accessibility."
        }
        self.content = content
        isLocked = true
        phase = .idle
        password = ""
        message = nil
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit,
                                     .disableSessionTermination, .disableHideApplication]
        buildWindows()
        observe()
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.isLocked else { return }
                // A half-typed password is cleared after a minute of no typing.
                if self.phase == .password, Date().timeIntervalSince(self.lastKey) > 60 { self.cancelPassword() }
            }
        }
        beginUnlock()
        return nil
    }

    // MARK: - Unlock

    /// Any key or click on the shield: Touch ID if the Mac has it, else the password field.
    func beginUnlock() {
        guard isLocked, phase == .idle else { return }
        message = nil
        let ctx = LAContext()
        ctx.localizedFallbackTitle = ""
        if ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            authContext = ctx
            phase = .touchID
        } else {
            phase = .password
        }
    }

    /// Called by the embedded Touch ID view once it's on screen, so the prompt
    /// renders inside the shield instead of as a system dialog underneath it.
    func evaluateTouchID(_ ctx: LAContext) {
        ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "unlock your screen") { [weak self] ok, error in
            let code = (error as? LAError)?.code
            Task { @MainActor in
                guard let self, self.authContext === ctx else { return }
                self.authContext = nil
                if ok { self.unlock(); return }
                switch code {
                case .biometryLockout:
                    self.phase = .password
                    self.message = "Touch ID is locked after too many tries. Use your password."
                case .userFallback:
                    self.phase = .password
                case .userCancel, .systemCancel, .appCancel, .none:
                    self.phase = .idle
                default:
                    self.phase = .idle
                    self.message = "Touch ID didn't match. Press any key to try again."
                }
            }
        }
    }

    func usePassword() {
        authContext?.invalidate()
        authContext = nil
        message = nil
        phase = .password
    }

    func cancelPassword() {
        password = ""
        message = nil
        phase = .idle
    }

    func submitPassword() {
        guard phase == .password, !password.isEmpty else { return }
        let pw = password
        phase = .checking
        Task.detached(priority: .userInitiated) {
            let outcome = LoginPassword.verify(pw)
            await MainActor.run { [weak self] in self?.finish(outcome) }
        }
    }

    private func finish(_ outcome: LoginPassword.Outcome) {
        guard isLocked else { return }
        password = ""
        switch outcome {
        case .ok:
            unlock()
        case .wrong:
            wrongCount += 1
            message = "Wrong password"
            phase = .password
        case .backoff:
            message = "Too many tries. Wait a minute, then try again."
            phase = .password
        case .unavailable:
            systemPromptFallback()
        }
    }

    /// Open Directory couldn't check the password (rare: directory/account
    /// trouble). Step aside for the system's own prompt; re-lock after 30s.
    private func systemPromptFallback() {
        standingDown = true
        removeTap()
        windows.forEach { $0.orderOut(nil) }
        NSApp.presentationOptions = []
        let ctx = LAContext()
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock your screen") { [weak self] ok, _ in
            Task { @MainActor in
                guard let self, self.standingDown else { return }
                if ok { self.unlock() } else { self.resumeAfterStandDown() }
            }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, self.standingDown else { return }
            ctx.invalidate()
            self.resumeAfterStandDown()
        }
    }

    private func resumeAfterStandDown() {
        standingDown = false
        phase = .idle
        message = "Couldn't check your password. Press any key to try again."
        guard let gestures = lastGestureSetting, installTap(blockGestures: gestures) else { unlock(); return }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit,
                                     .disableSessionTermination, .disableHideApplication]
        buildWindows()
    }

    func unlock() {
        authContext?.invalidate()
        authContext = nil
        idleTask?.cancel()
        standingDown = false
        removeTap()
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
        windows.forEach { $0.orderOut(nil) }
        windows = []
        NSApp.presentationOptions = []
        isLocked = false
        phase = .idle
        password = ""
        message = nil
        onUnlock()
    }

    // MARK: - Shield windows

    private func buildWindows() {
        windows.forEach { $0.orderOut(nil) }
        let screens = NSScreen.screens
        windows = screens.enumerated().map { i, screen in
            let w = ShieldWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isOpaque = true
            w.backgroundColor = .black
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.animationBehavior = .none
            // screens[0] holds the menu bar — that's where the unlock controls go.
            w.contentView = NSHostingView(rootView: content(i == 0).environment(\.colorScheme, .dark))
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            return w
        }
        windows.first?.makeKeyAndOrderFront(nil)
    }

    private func observe() {
        let app = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        observers = [
            (app, app.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self, self.isLocked, !self.standingDown { self.buildWindows() } }
            }),
            (app, app.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reclaimFront() }
            }),
            (ws, ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isLocked, !self.standingDown else { return }
                    if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    self.reclaimFront()
                }
            }),
        ]
    }

    /// Something took focus (a system alert, a notification click) — take it back.
    private func reclaimFront() {
        guard isLocked, !standingDown else { return }
        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.orderFrontRegardless() }
        windows.first?.makeKey()
    }

    // MARK: - Event tap

    @ObservationIgnored private var lastGestureSetting: Bool?

    private func installTap(blockGestures: Bool) -> Bool {
        removeTap()
        lastGestureSetting = blockGestures
        var mask: CGEventMask = 0
        // keyDown, keyUp, flagsChanged, NX_SYSDEFINED (media, brightness, Mission Control keys),
        // other mouse buttons (often mapped to Mission Control / app switching).
        for raw: UInt32 in [10, 11, 12, 14, 25, 26] { mask |= 1 << CGEventMask(raw) }
        if blockGestures {
            // scroll, gesture begin/end, gesture, magnify, swipe, rotate, smart magnify, pressure.
            for raw: UInt32 in [22, 18, 19, 20, 29, 30, 31, 32, 34] { mask |= 1 << CGEventMask(raw) }
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<ScreenLocker>.fromOpaque(info).takeUnretainedValue()
                let pass = MainActor.assumeIsolated { me.allows(type, event) }
                return pass ? Unmanaged.passUnretained(event) : nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source
        return true
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
    }

    /// true = deliver the event. Only plain typing reaches the password field;
    /// everything else is swallowed. A key press on the idle shield starts unlock.
    private func allows(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap, isLocked { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .keyDown, .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if phase == .password, LockKeys.allowsTyping(keyCode: code, flags: event.flags.rawValue) {
                lastKey = Date()
                return true
            }
            if type == .keyDown {
                switch phase {
                case .idle: beginUnlock()
                case .touchID: usePassword()
                default: break
                }
            }
            return false
        case .flagsChanged:
            return phase == .password
        default:
            return false
        }
    }
}

/// Borderless windows can't take keyboard focus by default; the password field needs it.
private final class ShieldWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
