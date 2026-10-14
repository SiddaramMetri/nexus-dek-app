import AppKit
import KavachCore
import SwiftUI

/// Guard: lock the screen when you step away, keep the Mac awake for long
/// builds. Owns the hotkey, the power assertions and the locker.
@MainActor @Observable
final class GuardModel {
    var settings: GuardSettings {
        didSet {
            guard settings != oldValue else { return }
            Stores.guardSettings.save(settings)
            if settings.lockShortcut != oldValue.lockShortcut { registerHotKey() }
            if settings.keepDisplayOn != oldValue.keepDisplayOn, isAwake { power.hold(display: settings.keepDisplayOn) }
            changed()
        }
    }

    let locker = ScreenLocker()
    /// When the current keep-awake session ends; nil while off or with no limit.
    private(set) var awakeUntil: Date?
    private(set) var isAwake = false
    private(set) var hasAccessibility = ScreenLocker.hasAccessibility(prompt: false)
    private(set) var launchAtLogin = LoginItem.isEnabled
    /// Set when the last lock attempt was refused (no permission, tap failed).
    var lockError: String?

    var onChange: () -> Void = {}
    /// A lock was refused (e.g. no Accessibility) — the app shows the Guard tab.
    var onLockRefused: () -> Void = {}
    /// Routes user-facing messages to the app's toasts.
    var notify: (String) -> Void = { _ in }

    @ObservationIgnored private let power = PowerAssertions()
    @ObservationIgnored private let hotKey = GlobalHotKey()
    @ObservationIgnored private var awakeTask: Task<Void, Never>?

    init() {
        settings = Stores.guardSettings.load() ?? GuardSettings()
        locker.onUnlock = { [weak self] in self?.changed() }
    }

    func start() {
        registerHotKey()
        if settings.awakeOnLaunch { startAwake(minutes: settings.awakeMinutes) }
    }

    private func changed() { onChange() }

    // MARK: - Lock

    func lock() {
        let gestures = settings.blockGestures
        if let error = locker.lock(blockGestures: gestures, content: { [unowned self] primary in
            AnyView(LockScreenView(guardModel: self, primary: primary))
        }) {
            lockError = error
            refreshPermissions()
            notify(error)
            onLockRefused()
        } else {
            lockError = nil
            hasAccessibility = true
        }
        changed()
    }

    private func registerHotKey() {
        hotKey.set(settings.lockShortcut) { [weak self] in self?.lock() }
    }

    func refreshPermissions() {
        hasAccessibility = ScreenLocker.hasAccessibility(prompt: false)
        launchAtLogin = LoginItem.isEnabled
        if hasAccessibility { lockError = nil }
    }

    func openAccessibilitySettings() {
        _ = ScreenLocker.hasAccessibility(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.set(on)
        } catch {
            if LoginItem.needsApproval { LoginItem.openSettings() } else { notify("Couldn't change Launch at login: \(error.localizedDescription)") }
        }
        launchAtLogin = LoginItem.isEnabled
    }

    // MARK: - Keep awake

    /// minutes == 0 → until turned off.
    func startAwake(minutes: Int) {
        if let reason = KeepAwakePolicy.stopReason(now: Date(), endsAt: nil, battery: BatteryState.current(),
                                                   cutoff: settings.batteryCutoff) {
            notify(message(for: reason))
            return
        }
        power.hold(display: settings.keepDisplayOn)
        isAwake = power.isHeld
        guard isAwake else { notify("macOS refused the keep-awake request."); return }
        awakeUntil = minutes > 0 ? Date().addingTimeInterval(TimeInterval(minutes * 60)) : nil
        watchAwake()
        changed()
    }

    func stopAwake(reason: KeepAwakePolicy.StopReason? = nil) {
        awakeTask?.cancel()
        awakeTask = nil
        power.release()
        isAwake = false
        awakeUntil = nil
        if let reason { Notifier.post(title: "Keep awake ended", body: message(for: reason)) }
        changed()
    }

    func toggleAwake() {
        if isAwake { stopAwake() } else { startAwake(minutes: settings.awakeMinutes) }
    }

    /// "Keeping awake · 42 min left" / "Keeping awake until you turn it off".
    var awakeStatus: String? {
        guard isAwake else { return nil }
        return awakeUntil.map { "Keeping awake · \(KeepAwakePolicy.remaining(until: $0))" } ?? "Keeping awake until you turn it off"
    }

    /// Wakes at the session end, or every 30s to check the battery.
    private func watchAwake() {
        awakeTask?.cancel()
        awakeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let left = self.awakeUntil.map { $0.timeIntervalSinceNow } ?? 30
                try? await Task.sleep(for: .seconds(max(1, min(30, left))))
                if Task.isCancelled { return }
                if let reason = KeepAwakePolicy.stopReason(now: Date(), endsAt: self.awakeUntil,
                                                           battery: BatteryState.current(), cutoff: self.settings.batteryCutoff) {
                    self.stopAwake(reason: reason)
                    return
                }
            }
        }
    }

    private func message(for reason: KeepAwakePolicy.StopReason) -> String {
        switch reason {
        case .timeUp: "Time's up — your Mac can sleep normally again."
        case let .lowBattery(p): "Battery is at \(p)% — keep awake is off so your Mac can sleep."
        }
    }
}
