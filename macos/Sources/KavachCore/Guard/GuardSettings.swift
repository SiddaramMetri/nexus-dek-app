import Foundation

/// Global shortcut that locks the screen. Raw values are persisted.
public enum LockShortcut: String, Codable, CaseIterable, Sendable {
    case ctrlCmdL, optCmdL, ctrlShiftL, ctrlOptCmdL, off

    public var label: String {
        switch self {
        case .ctrlCmdL: "⌃⌘L"
        case .optCmdL: "⌥⌘L"
        case .ctrlShiftL: "⌃⇧L"
        case .ctrlOptCmdL: "⌃⌥⌘L"
        case .off: "Off"
        }
    }

    /// Virtual key code of L (kVK_ANSI_L); nil = no shortcut.
    public var keyCode: UInt32? { self == .off ? nil : 37 }

    /// Carbon modifier mask (cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000).
    public var carbonModifiers: UInt32 {
        switch self {
        case .ctrlCmdL: 0x1000 | 0x100
        case .optCmdL: 0x800 | 0x100
        case .ctrlShiftL: 0x1000 | 0x200
        case .ctrlOptCmdL: 0x1000 | 0x800 | 0x100
        case .off: 0
        }
    }
}

/// Persisted Guard options (`guard.json`).
public struct GuardSettings: Codable, Equatable, Sendable {
    public var lockShortcut: LockShortcut = .ctrlCmdL
    /// Swallow trackpad swipes/pinches and scrolling while locked.
    public var blockGestures = true
    /// Keep-awake session length; 0 = until turned off.
    public var awakeMinutes = 60
    public var keepDisplayOn = false
    /// Stop keeping awake on battery at or under this percent; 0 = never.
    public var batteryCutoff = 20
    public var awakeOnLaunch = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case lockShortcut, blockGestures, awakeMinutes, keepDisplayOn, batteryCutoff, awakeOnLaunch
    }

    /// Lenient: the file is user-editable, so every field falls back to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GuardSettings()
        lockShortcut = (try? c.decode(LockShortcut.self, forKey: .lockShortcut)) ?? d.lockShortcut
        blockGestures = (try? c.decode(Bool.self, forKey: .blockGestures)) ?? d.blockGestures
        awakeMinutes = (try? c.decode(Int.self, forKey: .awakeMinutes)).map { max(0, $0) } ?? d.awakeMinutes
        keepDisplayOn = (try? c.decode(Bool.self, forKey: .keepDisplayOn)) ?? d.keepDisplayOn
        batteryCutoff = (try? c.decode(Int.self, forKey: .batteryCutoff)).map { min(max(0, $0), 90) } ?? d.batteryCutoff
        awakeOnLaunch = (try? c.decode(Bool.self, forKey: .awakeOnLaunch)) ?? d.awakeOnLaunch
    }
}

public extension Stores {
    static let guardSettings = JSONStore<GuardSettings>(file: "guard.json", key: "guard")
}
