import Foundation
import KavachCore
import Observation

/// One scan at a time: reset → findings stream in per probe → settle on the
/// severity-sorted report. Probes never throw (one that can't read its source
/// reports that as a finding), so there is no scan-level error state. Lives for
/// the app's lifetime so a report (or a running deep scan) survives tab switches.
@MainActor @Observable
final class DoctorScanModel {
    static let shared = DoctorScanModel()

    private(set) var findings: [Finding] = []
    private(set) var scanning = false
    private(set) var deepScanning = false
    private(set) var hasScanned = false
    private(set) var progress: ScanProgress?

    private var task: Task<Void, Never>?
    /// Bumped on every start/cancel so an abandoned scan's late events are dropped.
    private var generation = 0

    var isBusy: Bool { scanning || deepScanning }

    func scan() { start(deep: false) }

    /// Deep scan = the full quick scan PLUS the slow sweep — one complete
    /// report, so it replaces whatever was on screen (same as scan).
    func deepScan() { start(deep: true) }

    /// Scans are read-only, so cancel doesn't wait for anything to unwind:
    /// leave the scanning state now (instant feedback), cancel the task (the
    /// running `du`/`find` is terminated) and go back to the clean start screen.
    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        scanning = false
        deepScanning = false
        progress = nil
        findings = []
        hasScanned = false
    }

    private func start(deep: Bool) {
        task?.cancel()
        generation += 1
        let gen = generation
        findings = []
        progress = nil
        scanning = !deep
        deepScanning = deep
        let events = deep ? DoctorEngine.deepScan() : DoctorEngine.scan()
        task = Task { [weak self] in
            for await event in events {
                guard let self, gen == self.generation else { return }
                switch event {
                case let .progress(p): if deep { self.progress = p }
                case let .findings(f): self.findings += f
                }
            }
            guard let self, gen == self.generation, !Task.isCancelled else { return }
            self.findings = DoctorEngine.sorted(self.findings)
            self.hasScanned = true
            self.scanning = false
            self.deepScanning = false
            self.progress = nil
        }
    }
}
