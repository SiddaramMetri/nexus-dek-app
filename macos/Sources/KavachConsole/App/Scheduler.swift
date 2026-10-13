import Foundation
import KavachCore

/// Tray automation while the app runs: daily auto-archive of old Claude chats
/// and VACUUM of bloated VSCode DBs whenever VSCode is closed. Both opt-in, and
/// each also needs its owning module on. Coarse 5-minute tick; settings are
/// read live so toggles apply immediately.
@MainActor
enum Scheduler {
    static let tick: Duration = .seconds(5 * 60)
    static let daily: TimeInterval = 24 * 60 * 60

    static func start(model: AppModel) {
        Task { @MainActor [weak model] in
            var lastArchive: Date?
            var diskWarningArmed = true
            while let model {
                let s = model.settings
                if s.autoArchiveEnabled, s.isEnabled(.claude),
                   lastArchive.map({ Date().timeIntervalSince($0) >= daily }) ?? true {
                    let days = min(max(s.autoArchiveCutoffDays, 1), 3650)
                    if let msg = await ClaudeArchiver.autoArchiveAll(cutoffDays: days) {
                        Notifier.post(title: "\(AppInfo.name)", body: msg)
                    }
                    lastArchive = Date()
                }
                if s.autoVacuumEnabled, s.isEnabled(.doctor), !(await VSCodeDoctor.stateDBsInUse()),
                   let msg = try? await VSCodeDoctor.vacuumBloated(), msg.hasPrefix("Freed") {
                    Notifier.post(title: "\(AppInfo.name)", body: msg)
                }
                if s.lowDiskWarning, let disk = DiskSpace.current(),
                   DiskSpace.shouldWarn(free: disk.free, armed: &diskWarningArmed) {
                    Notifier.post(title: "Your Mac is low on space",
                                  body: "Only \(Format.bytes(disk.free)) free. Dev cleanup in \(AppInfo.name) can find space you don't need.")
                }
                try? await Task.sleep(for: tick)
            }
        }
    }
}
