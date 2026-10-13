import Foundation
import IOKit.ps

public struct BatteryState: Equatable, Sendable {
    public let percent: Int
    public let onBattery: Bool
    public init(percent: Int, onBattery: Bool) {
        self.percent = percent
        self.onBattery = onBattery
    }

    /// The internal battery, or nil on a Mac without one (desktop).
    public static func current() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onBattery = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue
            return BatteryState(percent: min(100, cur * 100 / max), onBattery: onBattery)
        }
        return nil
    }
}

public enum KeepAwakePolicy {
    /// Session lengths offered in the UI, in minutes; 0 = until turned off.
    public static let durations = [5, 15, 60, 120, 300, 0]
    /// Battery cutoffs offered in the UI; 0 = never.
    public static let cutoffs = [0, 10, 15, 20, 30, 40]

    public enum StopReason: Equatable, Sendable {
        case timeUp
        case lowBattery(Int)
    }

    /// Why a running session should end now, or nil to keep going. The battery
    /// cutoff only applies while running on battery — plugged in never stops it.
    public static func stopReason(now: Date, endsAt: Date?, battery: BatteryState?, cutoff: Int) -> StopReason? {
        if let endsAt, now >= endsAt { return .timeUp }
        if cutoff > 0, let battery, battery.onBattery, battery.percent <= cutoff { return .lowBattery(battery.percent) }
        return nil
    }

    /// "5 min" · "1 hour" · "2 hours" · "Until turned off"
    public static func label(minutes: Int) -> String {
        switch minutes {
        case 0: "Until turned off"
        case 60: "1 hour"
        case let m where m % 60 == 0: "\(m / 60) hours"
        default: "\(minutes) min"
        }
    }

    /// "42 min left" · "1 h 05 min left" · "under a minute left"
    public static func remaining(until end: Date, now: Date = Date()) -> String {
        let secs = Int(end.timeIntervalSince(now).rounded(.up))
        guard secs >= 60 else { return "under a minute left" }
        let m = (secs + 59) / 60
        return m >= 60 ? String(format: "%d h %02d min left", m / 60, m % 60) : "\(m) min left"
    }
}

/// Which keystrokes reach the password field while the lock screen is up.
/// Everything with ⌘ or ⌃ is swallowed (app switching, Spotlight, Mission
/// Control, Quit…), as are F-keys and the Mission Control/Launchpad keys.
public enum LockKeys {
    /// CGEventFlags.maskCommand | .maskControl
    static let blockedFlags: UInt64 = 0x100000 | 0x40000
    /// F1–F20, plus Mission Control (160), Launchpad (131), Spotlight/Dictation/DND (176–179), and
    /// the legacy Help/Function keys (114, 63).
    static let blockedKeyCodes: Set<Int64> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
        160, 131, 130, 176, 177, 178, 179, 114, 63,
    ]

    public static func allowsTyping(keyCode: Int64, flags: UInt64) -> Bool {
        flags & blockedFlags == 0 && !blockedKeyCodes.contains(keyCode)
    }
}
