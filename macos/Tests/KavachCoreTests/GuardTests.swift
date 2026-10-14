import Foundation
import Testing
@testable import KavachCore

@Suite struct GuardSettingsTests {
    @Test func defaultsWhenFileIsEmpty() throws {
        let s = try JSONDecoder().decode(GuardSettings.self, from: Data("{}".utf8))
        #expect(s == GuardSettings())
        #expect(s.lockShortcut == .ctrlCmdL)
        #expect(s.blockGestures)
        #expect(s.batteryCutoff == 20)
    }

    @Test func badFieldsFallBackOneByOne() throws {
        let json = #"{"lockShortcut":"hyperL","awakeMinutes":-5,"batteryCutoff":500,"keepDisplayOn":true}"#
        let s = try JSONDecoder().decode(GuardSettings.self, from: Data(json.utf8))
        #expect(s.lockShortcut == .ctrlCmdL)
        #expect(s.awakeMinutes == 0)
        #expect(s.batteryCutoff == 90)
        #expect(s.keepDisplayOn)
    }

    @Test func roundTrips() throws {
        var s = GuardSettings()
        s.lockShortcut = .optCmdL
        s.awakeMinutes = 120
        s.awakeOnLaunch = true
        let back = try JSONDecoder().decode(GuardSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func shortcutsMapToCarbonMasks() {
        #expect(LockShortcut.ctrlCmdL.carbonModifiers == 0x1100)
        #expect(LockShortcut.optCmdL.carbonModifiers == 0x900)
        #expect(LockShortcut.ctrlShiftL.carbonModifiers == 0x1200)
        #expect(LockShortcut.ctrlOptCmdL.carbonModifiers == 0x1900)
        #expect(LockShortcut.ctrlCmdL.keyCode == 37)
        #expect(LockShortcut.off.keyCode == nil)
    }
}

@Suite struct KeepAwakePolicyTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func runsUntilTheEnd() {
        let end = now.addingTimeInterval(60)
        #expect(KeepAwakePolicy.stopReason(now: now, endsAt: end, battery: nil, cutoff: 20) == nil)
        #expect(KeepAwakePolicy.stopReason(now: end, endsAt: end, battery: nil, cutoff: 20) == .timeUp)
    }

    @Test func noLimitNeverTimesOut() {
        #expect(KeepAwakePolicy.stopReason(now: now.addingTimeInterval(1e7), endsAt: nil, battery: nil, cutoff: 20) == nil)
    }

    @Test func lowBatteryOnlyCountsOnBattery() {
        let low = BatteryState(percent: 15, onBattery: true)
        let charging = BatteryState(percent: 15, onBattery: false)
        #expect(KeepAwakePolicy.stopReason(now: now, endsAt: nil, battery: low, cutoff: 20) == .lowBattery(15))
        #expect(KeepAwakePolicy.stopReason(now: now, endsAt: nil, battery: charging, cutoff: 20) == nil)
        #expect(KeepAwakePolicy.stopReason(now: now, endsAt: nil, battery: low, cutoff: 0) == nil)
        #expect(KeepAwakePolicy.stopReason(now: now, endsAt: nil, battery: BatteryState(percent: 20, onBattery: true), cutoff: 20) == .lowBattery(20))
    }

    @Test func labels() {
        #expect(KeepAwakePolicy.label(minutes: 5) == "5 min")
        #expect(KeepAwakePolicy.label(minutes: 60) == "1 hour")
        #expect(KeepAwakePolicy.label(minutes: 300) == "5 hours")
        #expect(KeepAwakePolicy.label(minutes: 0) == "Until turned off")
    }

    @Test func remainingRoundsUp() {
        #expect(KeepAwakePolicy.remaining(until: now.addingTimeInterval(30), now: now) == "under a minute left")
        #expect(KeepAwakePolicy.remaining(until: now.addingTimeInterval(61), now: now) == "2 min left")
        #expect(KeepAwakePolicy.remaining(until: now.addingTimeInterval(42 * 60), now: now) == "42 min left")
        #expect(KeepAwakePolicy.remaining(until: now.addingTimeInterval(65 * 60), now: now) == "1 h 05 min left")
    }
}

@Suite struct LockKeysTests {
    @Test func plainTypingPasses() {
        #expect(LockKeys.allowsTyping(keyCode: 0, flags: 0))  // a
        #expect(LockKeys.allowsTyping(keyCode: 0, flags: 0x20000))  // ⇧A
        #expect(LockKeys.allowsTyping(keyCode: 0, flags: 0x80000))  // ⌥a
        #expect(LockKeys.allowsTyping(keyCode: 36, flags: 0))  // Return
        #expect(LockKeys.allowsTyping(keyCode: 51, flags: 0))  // Delete
        #expect(LockKeys.allowsTyping(keyCode: 53, flags: 0))  // Esc
        #expect(LockKeys.allowsTyping(keyCode: 123, flags: 0x800000))  // ← (arrows carry the fn flag)
    }

    @Test func shortcutsAndSystemKeysAreSwallowed() {
        #expect(!LockKeys.allowsTyping(keyCode: 48, flags: 0x100000))  // ⌘Tab
        #expect(!LockKeys.allowsTyping(keyCode: 49, flags: 0x100000))  // ⌘Space
        #expect(!LockKeys.allowsTyping(keyCode: 12, flags: 0x100000))  // ⌘Q
        #expect(!LockKeys.allowsTyping(keyCode: 124, flags: 0x40000))  // ⌃→ (switch Space)
        #expect(!LockKeys.allowsTyping(keyCode: 160, flags: 0))  // Mission Control
        #expect(!LockKeys.allowsTyping(keyCode: 99, flags: 0x800000))  // F3
    }
}
