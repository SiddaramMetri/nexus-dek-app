import AppKit
import KavachCore
import SwiftUI

/// Stopping a server that launchd keeps alive: killing the process is useless
/// (macOS restarts it), so the user picks how to stop the job itself.
@MainActor
enum LaunchdPrompt {
    enum Choice { case untilLogin, keepOff }

    static func ask(job: LaunchdJob, name: String, window: NSWindow?) async -> Choice? {
        let alert = NSAlert()
        alert.messageText = "\(name) restarts by itself"
        alert.informativeText = """
        macOS keeps it running through the background job “\(job.label)”, so stopping the process only makes it start again.

        Stop the job instead:
        • Until next login — it comes back after you log out or restart.
        • And don't auto-start — it stays off until you turn it back on (from its project card or the Ports tab).
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop until next login")
        alert.addButton(withTitle: "Stop and don't auto-start").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let response: NSApplication.ModalResponse
        if let window, window.isVisible {
            response = await withCheckedContinuation { cont in alert.beginSheetModal(for: window) { cont.resume(returning: $0) } }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            response = alert.runModal()
        }
        switch response {
        case .alertFirstButtonReturn: return .untilLogin
        case .alertSecondButtonReturn: return .keepOff
        default: return nil
        }
    }

    /// Stops a launchd-managed server the right way; falls back to the normal
    /// stop sheet for system jobs (which this app never unloads).
    static func stop(_ port: PortInfo, name: String, projectRoot: String?, model: AppModel,
                     fallback: (PortInfo) -> Void) {
        guard let job = port.launchdJob, job.isUserAgent else { fallback(port); return }
        Task {
            guard let choice = await ask(job: job, name: name, window: model.confirmer.window) else { return }
            do {
                try await model.track("Stopping \(job.label)") {
                    try await LaunchdJobs.stop(job, keepOff: choice == .keepOff, projectRoot: projectRoot)
                }
                model.toast(choice == .keepOff ? "Stopped \(name) — it won't auto-start" : "Stopped \(name) until next login")
                await PortsStore.shared.reload()
            } catch {
                model.report(error)
            }
        }
    }

    static func turnBackOn(_ job: StoppedJob, model: AppModel) {
        model.perform("\(job.label) is back on") {
            try await LaunchdJobs.turnBackOn(job)
            await PortsStore.shared.reload()
        }
    }
}

/// "Auto-restarts" badge for launchd-managed servers.
struct AutoRestartBadge: View {
    let job: LaunchdJob

    var body: some View {
        Label("Auto-restarts", systemImage: "arrow.clockwise.circle")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.orange)
            .background(Color.orange.opacity(0.12), in: Capsule())
            .help("macOS keeps this running via the launchd job “\(job.label)”. Stopping it stops the job.")
    }
}

/// Jobs the user turned off for this project, each with "Turn back on".
struct StoppedJobsRow: View {
    @Environment(AppModel.self) private var model
    let projectRoot: String
    @ViewState private var jobs: [StoppedJob] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(jobs, id: \.label) { job in
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary)
                    Text("Auto-start off: \(job.label)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Turn back on") {
                        LaunchdPrompt.turnBackOn(job, model: model)
                        jobs.removeAll { $0.label == job.label }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
        .onAppear { jobs = LaunchdJobs.stopped(forProject: projectRoot) }
    }
}
