import Foundation
import Testing
@testable import KavachCore

private func finding(id probeId: String = "p", scope: Scope = .system, _ severity: Severity = .green,
                     tag: KavachCore.Tag = .speed, _ summary: String = "s", explain: String = "e") -> Finding {
    Finding(probeId: probeId, scope: scope, severity: severity, tag: tag, summary: summary, explain: explain)
}

/// Records every confirm and answers with `answer`.
private final class RecordingConfirmer: Confirmer, @unchecked Sendable {
    let answer: Bool
    private let lock = NSLock()
    private var _titles: [String] = []
    var titles: [String] { lock.withLock { _titles } }

    init(answer: Bool) { self.answer = answer }

    func confirm(title: String, message: String, action: String, destructive: Bool) async -> Bool {
        lock.withLock { _titles.append(title) }
        return answer
    }
}

@Suite struct DoctorEngineTests {
    @Test func registryOrderAndScopes() {
        let ids = DoctorEngine.registry.map(\.id)
        #expect(ids.first == "disk_free")
        #expect(ids.firstIndex(of: "startup_items")! < ids.firstIndex(of: VSCodeDoctor.orphans.id)!)
        #expect(ids.firstIndex(of: VSCodeDoctor.extensionAudit.id)! < ids.firstIndex(of: "ollama_models")!)
        #expect(ids.last == "browser_extensions")
        #expect(DoctorEngine.probes(for: []).isEmpty)
        #expect(DoctorEngine.probes(for: [.disk]).first?.id == "disk_free")
        #expect(DoctorEngine.probes(for: [.system]).first?.id == "load_vs_cores")
        #expect(DoctorEngine.probes(for: [.startup]).map(\.id) == ["startup_items"])
        #expect(DeepScan.registry.map(\.id) == ["node_modules_sweep", "dev_caches"])
        #expect(Array(DoctorEngine.deepScanProbes().suffix(2).map(\.id)) == ["node_modules_sweep", "dev_caches"])
    }

    /// Probes run concurrently but are delivered in registry order, each
    /// preceded by a progress event naming the probe being waited on.
    @Test func deliversInRegistryOrderWithProgress() async {
        let slow = Probe(id: "slow", scope: .system) {
            try? await Task.sleep(for: .milliseconds(150))
            return [finding(id: "slow", .yellow)]
        }
        let fast = Probe(id: "fast", scope: .disk) { [finding(id: "fast", .red), finding(id: "fast", .green, "x")] }
        let events = DoctorEngine.stream { [slow, fast] }
        var log: [ScanEvent] = []
        for await e in events { log.append(e) }
        #expect(log == [
            .progress(ScanProgress(probeId: "slow", index: 0, total: 2)),
            .findings([finding(id: "slow", .yellow)]),
            .progress(ScanProgress(probeId: "fast", index: 1, total: 2)),
            .findings([finding(id: "fast", .red), finding(id: "fast", .green, "x")]),
        ])
    }

    /// Measures peak overlap instead of wall time, so a busy machine can't flake it.
    @Test func probesRunConcurrently() async {
        let inFlight = Locked((now: 0, peak: 0))
        let probes = (0..<4).map { i in
            Probe(id: "p\(i)", scope: .system) {
                inFlight.with { $0.now += 1; $0.peak = max($0.peak, $0.now) }
                try? await Task.sleep(for: .milliseconds(200))
                inFlight.with { $0.now -= 1 }
                return [finding(id: "p\(i)")]
            }
        }
        let report = await DoctorEngine.report(DoctorEngine.stream { probes })
        #expect(report.count == 4)
        #expect(inFlight.snapshot.peak > 1)
    }

    /// Dropping the stream cancels the scan: the probe's own loop sees it.
    @Test func cancellationReachesProbes() async {
        let sawCancel = Locked(false)
        let looping = Probe(id: "loop", scope: .disk) {
            for _ in 0..<200 {
                if Task.isCancelled { sawCancel.with { $0 = true }; break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return []
        }
        let consumer = Task {
            for await _ in DoctorEngine.stream({ [looping] }) {}
        }
        try? await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        await consumer.value
        for _ in 0..<100 where !sawCancel.snapshot { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(sawCancel.snapshot)
    }

    @Test func emptyScanFinishesImmediately() async {
        #expect(await DoctorEngine.report(DoctorEngine.stream { [] }).isEmpty)
    }

    @Test func sortIsRedFirstAndStable() {
        let sorted = DoctorEngine.sorted([finding(id: "a", .green), finding(id: "b", .yellow), finding(id: "c", .red),
                                          finding(id: "d", .yellow), finding(id: "e", .green)])
        #expect(sorted.map(\.probeId) == ["c", "b", "d", "a", "e"])
    }
}

@Suite struct DoctorFixTests {
    @Test func fixMetaLabels() {
        #expect(DoctorFix.meta(nil) == nil)
        #expect(DoctorFix.meta("nope") == nil)
        #expect(DoctorFix.meta("ollama_rm:llama3:latest")?.label == "Delete model")
        #expect(DoctorFix.meta("browser_cache:Chrome")?.label == "Clear cache")
        #expect(DoctorFix.meta("vscode_ext_rm:ms-python.python")?.label == "Uninstall")
        #expect(DoctorFix.meta("browser_ext_manage:Brave:abc")?.label == "Manage in Brave")
        #expect(DoctorFix.meta("vscode_vacuum")?.label == "VACUUM now")
        #expect(DoctorFix.meta("pnpm_orphan_stores")?.label == "Delete old pnpm stores")
    }

    @Test func destructiveStyling() {
        #expect(DoctorFix.meta("cache_npm")?.destructive == true)
        #expect(DoctorFix.meta("ollama_rm:x:y")?.destructive == true)
        #expect(DoctorFix.meta("vscode_ext_rm:x")?.destructive == true)
        #expect(DoctorFix.meta("vscode_vacuum")?.destructive == false)
        #expect(DoctorFix.meta("browser_ext_manage:Chrome:x")?.destructive == false)
    }

    /// The confirm lives inside KavachCore: a declined confirm stops the fix
    /// before anything is touched.
    @Test func declinedConfirmCancelsBeforeMutating() async {
        let confirmer = RecordingConfirmer(answer: false)
        await #expect(throws: AppError.userCancelled) {
            try await DoctorFix.run("cache_gradle", confirmer: confirmer)
        }
        #expect(confirmer.titles == ["Clear Gradle caches?"])
    }

    @Test func unknownFixIdIsRejectedWithoutConfirm() async {
        let confirmer = RecordingConfirmer(answer: true)
        await #expect(throws: AppError.self) { try await DoctorFix.run("rm_-rf_slash", confirmer: confirmer) }
        #expect(confirmer.titles.isEmpty)
    }

    @Test func deepFixConfirmationCopy() async {
        let dead = await DeepScan.fixConfirmation("deep_dead_node_modules")
        #expect(dead?.title == "Delete dead node_modules?")
        let cache = await DeepScan.fixConfirmation("cache_npm")
        #expect(cache?.message.contains("does not make the machine faster") == true)
        #expect(await DeepScan.fixConfirmation("rm_-rf_slash") == nil)
    }
}

@Suite struct DoctorReportTests {
    @Test func splitsAttentionVsHealthyAndSortsRedFirst() {
        let md = DoctorReport.markdown([
            finding(.green, "all good"),
            finding(.yellow, tag: .storage, "meh"),
            finding(.red, "bad", explain: "why it matters"),
        ], dateLabel: "Jul 17 at 07:45 PM")
        #expect(md.contains("# \(AppInfo.shortName) Doctor report — Jul 17 at 07:45 PM"))
        #expect(md.contains("## Needs attention (2)"))
        #expect(md.contains("## Healthy (1)"))
        #expect(md.range(of: "bad")!.lowerBound < md.range(of: "meh")!.lowerBound)
        #expect(md.contains("**[Storage]** meh"))
        #expect(md.contains("  why it matters"))
    }

    @Test func emptyAttentionSectionStaysHonest() {
        let md = DoctorReport.markdown([finding()], dateLabel: "now")
        #expect(md.contains("## Needs attention (0)"))
        #expect(md.contains("- Nothing — all clear."))
    }

    @Test func overviewNestsItsRows() {
        let overview = finding(id: "ollama_models", scope: .disk, .yellow, "2 ollama models · 4.1 GB")
        let a = finding(id: "ollama_models", scope: .disk, .yellow, "a:latest · 2.0 GB · last used 4 months ago")
        let b = finding(id: "ollama_models", scope: .disk, .green, "b:latest · 2.1 GB · in use right now")
        let disk = finding(id: "disk_free", scope: .disk, .green, "200 GB free on /")
        let all = [overview, a, b, disk]
        #expect(DoctorReport.isOverview(overview))
        #expect(!DoctorReport.isOverview(a))
        #expect(DoctorReport.rows(all) == [overview, disk])
        #expect(DoctorReport.children(of: overview, in: all) == [a, b])
        #expect(DoctorReport.children(of: disk, in: all) == nil)
        // A child whose overview is filtered out still renders standalone.
        #expect(DoctorReport.rows([a, disk]) == [a, disk])
    }

    @Test func browserTabGroupsPerBrowser() {
        let chrome = finding(id: "browser_processes", scope: .browser, .green, "Chrome · 1.2 GB across 20 processes")
        let braveCache = finding(id: "browser_storage", scope: .browser, .yellow, "Brave cache · 300 MB reclaimable")
        let audio = finding(id: "browser_audio", scope: .browser, .green, "Nothing is holding an audio sleep assertion")
        let extOverview = finding(id: "browser_extensions", scope: .browser, .green, "1 extension · 0 run in background")
        let groups = DoctorReport.browserGroups([audio, extOverview, braveCache, chrome])
        #expect(groups.map(\.title) == ["Chrome", "Brave", "Extensions", "Power & audio"])
        #expect(groups[1].findings == [braveCache])
        #expect(DoctorReport.isOverview(extOverview))
    }
}
