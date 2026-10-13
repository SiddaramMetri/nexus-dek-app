import AppKit
import KavachCore

// Single instance: a second launch asks the running copy to show its window,
// then exits. An advisory file lock is per-app-binary, so it never collides
// with the old Tauri build sharing the same data directory.
let showNotification = Notification.Name("\(AppInfo.bundleID).show")
try? FileManager.default.createDirectory(at: Paths.appData, withIntermediateDirectories: true)
Paths.migrateLegacyData()
let lockFD = open(Paths.appData.appendingPathComponent(".native.lock").path, O_CREAT | O_RDWR, 0o600)
if lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    DistributedNotificationCenter.default().postNotificationName(showNotification, object: nil, deliverImmediately: true)
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
