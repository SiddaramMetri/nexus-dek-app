import Darwin
import Foundation

/// A launchd job that keeps a process alive — killing such a process only
/// makes macOS start it again (KeepAlive), so it must be stopped as a job.
public struct LaunchdJob: Equatable, Hashable, Sendable {
    public let label: String
    /// `~/Library/LaunchAgents/<label>.plist` when it's the user's own agent;
    /// nil for system jobs, which this app never touches.
    public let plistPath: String?

    public var isUserAgent: Bool { plistPath != nil }
}

/// One job the user turned off from this app, remembered so it can be turned back on.
public struct StoppedJob: Codable, Equatable, Sendable {
    public let label: String
    public let plistPath: String
    /// Project the job served (for the "turn back on" offer on its card).
    public let projectRoot: String?
    /// true = also disabled at login (`launchctl disable`).
    public let keptOff: Bool
}

public enum LaunchdJobs {
    public static let store = JSONStore<[StoppedJob]>(file: "launchd.json", key: "stopped")

    /// `launchctl list` → pid → label, for third-party jobs with a live pid.
    /// Apple's own jobs and per-app `application.*` entries are never offered.
    static func parse(_ out: String) -> [Int32: String] {
        var map: [Int32: String] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let f = line.split(whereSeparator: \.isWhitespace)
            guard f.count >= 3, let pid = Int32(f[0]) else { continue }
            let label = String(f[2])
            if label.hasPrefix("com.apple.") || label.hasPrefix("application.") { continue }
            map[pid] = label
        }
        return map
    }

    /// Jobs for the given pids (one `launchctl list` call).
    public static func jobs(forPids pids: Set<Int32>, home: URL = Paths.home) async -> [Int32: LaunchdJob] {
        guard !pids.isEmpty else { return [:] }
        let labels = parse(await Proc.anyOutput("launchctl", ["list"]))
        var out: [Int32: LaunchdJob] = [:]
        for pid in pids {
            guard let label = labels[pid], isValidLabel(label) else { continue }
            out[pid] = LaunchdJob(label: label, plistPath: userPlist(label, home: home))
        }
        return out
    }

    static func userPlist(_ label: String, home: URL) -> String? {
        let p = home.appendingPathComponent("Library/LaunchAgents/\(label).plist").path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    static func isValidLabel(_ label: String) -> Bool {
        label.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,200}$"#, options: .regularExpression) != nil
    }

    static var domain: String { "gui/\(getuid())" }

    /// Stops the job (bootout) so launchd stops restarting it. `keepOff` also
    /// disables it so it doesn't come back at the next login. The caller has
    /// already asked the user (the three-way prompt is the confirmation).
    public static func stop(_ job: LaunchdJob, keepOff: Bool, projectRoot: String?) async throws {
        guard let plist = job.plistPath, isValidLabel(job.label) else {
            throw AppError.forbidden("Only your own LaunchAgents can be stopped here.")
        }
        let out = try await Proc.run("launchctl", ["bootout", "\(domain)/\(job.label)"])
        // 3 = "No such process": already unloaded — that's the goal anyway.
        guard out.ok || out.status == 3 else {
            throw AppError.shell(out.err.isEmpty ? "launchctl couldn't stop \(job.label)" : out.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if keepOff { _ = try? await Proc.run("launchctl", ["disable", "\(domain)/\(job.label)"]) }
        var stopped = store.load() ?? []
        stopped.removeAll { $0.label == job.label }
        stopped.append(StoppedJob(label: job.label, plistPath: plist, projectRoot: projectRoot, keptOff: keepOff))
        store.save(stopped)
        Journal.write(action: "launchdStop", ["label": job.label, "keptOff": keepOff])
    }

    /// Undo: enable + load the agent again (it starts if its plist says RunAtLoad).
    public static func turnBackOn(_ job: StoppedJob) async throws {
        guard isValidLabel(job.label), FileManager.default.fileExists(atPath: job.plistPath),
              job.plistPath.hasPrefix(Paths.home.appendingPathComponent("Library/LaunchAgents").path + "/") else {
            throw AppError.notFound("\(job.label)'s LaunchAgent file is gone.")
        }
        _ = try? await Proc.run("launchctl", ["enable", "\(domain)/\(job.label)"])
        let out = try await Proc.run("launchctl", ["bootstrap", domain, job.plistPath])
        // 5 / 37 = already loaded.
        guard out.ok || out.status == 5 || out.status == 37 else {
            throw AppError.shell(out.err.isEmpty ? "launchctl couldn't start \(job.label)" : out.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        var stopped = store.load() ?? []
        stopped.removeAll { $0.label == job.label }
        store.save(stopped)
        Journal.write(action: "launchdStart", ["label": job.label])
    }

    public static func stopped(forProject root: String) -> [StoppedJob] {
        (store.load() ?? []).filter { $0.projectRoot == root }
    }
}
