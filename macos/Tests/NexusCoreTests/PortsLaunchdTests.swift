import Foundation
import Testing
@testable import NexusCore

@Suite struct PortsLaunchdTests {
    @Test func parsesThirdPartyJobsOnly() {
        let out = """
        PID\tStatus\tLabel
        45959\t-9\tcom.docklyt.agent
        26843\t1\tcom.loop.local-runner
        -\t0\tcom.example.stopped
        1065\t0\tapplication.com.microsoft.VSCode.1.2
        752\t0\tcom.apple.rapportd
        """
        let m = LaunchdJobs.parse(out)
        #expect(m == [45959: "com.docklyt.agent", 26843: "com.loop.local-runner"])
    }

    @Test func labelsAreValidated() {
        #expect(LaunchdJobs.isValidLabel("com.docklyt.agent"))
        #expect(!LaunchdJobs.isValidLabel("../evil"))
        #expect(!LaunchdJobs.isValidLabel("a b"))
        #expect(!LaunchdJobs.isValidLabel("x;rm"))
    }

    @Test func onlyUserAgentsGetAPlist() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ld-\(UUID().uuidString)")
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try Data().write(to: agents.appendingPathComponent("com.docklyt.agent.plist"))
        #expect(LaunchdJobs.userPlist("com.docklyt.agent", home: home) != nil)
        #expect(LaunchdJobs.userPlist("com.other.daemon", home: home) == nil)
    }

    @Test func systemJobsCannotBeStopped() async {
        let job = LaunchdJob(label: "com.vendor.daemon", plistPath: nil)
        #expect(!job.isUserAgent)
        await #expect(throws: AppError.self) { try await LaunchdJobs.stop(job, keepOff: false, projectRoot: nil) }
    }
}
