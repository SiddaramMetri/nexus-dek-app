import Foundation

/// Free space on the startup volume, as Finder reports it.
public enum DiskSpace {
    public struct Usage: Equatable, Sendable {
        public var free: UInt64
        public var total: UInt64
    }

    /// Warn below this; the warning re-arms once space recovers past `rearm`.
    public static let lowThreshold: UInt64 = 10_000_000_000
    public static let rearm: UInt64 = 12_000_000_000

    /// "Important usage" capacity counts purgeable space macOS would free on
    /// demand — the same number Finder and System Settings show.
    public static func current(_ volume: URL = Paths.home) -> Usage? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let v = try? volume.resourceValues(forKeys: keys),
              let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity
        else { return nil }
        return Usage(free: UInt64(max(0, free)), total: UInt64(max(0, total)))
    }

    /// Hysteresis for the low-space notification: fire once when free drops
    /// under the threshold, then stay quiet until it climbs back past `rearm`.
    public static func shouldWarn(free: UInt64, armed: inout Bool) -> Bool {
        if free >= rearm { armed = true; return false }
        guard armed, free < lowThreshold else { return false }
        armed = false
        return true
    }
}
