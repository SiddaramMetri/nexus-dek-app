import Foundation

// Nexus Doctor — the probe engine. A probe is read-only and must never wake a
// daemon (the watchman lesson). Mutations only ever happen via `DoctorFix`.

/// Deep-scan progress: sent before each probe is awaited so the UI can show
/// "scanning X…" plus a bar. Probes run concurrently — `probeId` names the one
/// currently being waited on (the slow tail in practice).
public struct ScanProgress: Equatable, Sendable {
    public let probeId: String
    public let index: Int
    public let total: Int
}

public enum ScanEvent: Equatable, Sendable {
    case progress(ScanProgress)
    /// One probe's findings, delivered in registry order as each completes.
    case findings([Finding])
}

public enum DoctorEngine {
    /// Report order. VSCode probes come from the VSCode port.
    public static let registry: [Probe] = [
        SystemProbes.diskFree,
        SystemProbes.loadVsCores,
        SystemProbes.lowPowerMode,
        SystemProbes.memoryTruth,
        SystemProbes.backupRisk,
        SystemProbes.startupItems,
        VSCodeDoctor.orphans,
        VSCodeDoctor.dbBloat,
        VSCodeDoctor.extensionAudit,
        OllamaProbe.models,
        BrowserProbes.processes,
        BrowserProbes.audioBlocker,
        BrowserProbes.storage,
        BrowserProbes.extensions,
    ]

    /// Probes that will actually run: requested scopes ∩ available, in registry order.
    public static func probes(for scopes: Set<Scope>) -> [Probe] {
        registry.filter { scopes.contains($0.scope) && $0.available() }
    }

    /// Deep scan = the FULL quick scan plus the slow sweep (node_modules + dev
    /// caches) — "deep" means more thorough, not a different report.
    public static func deepScanProbes() -> [Probe] {
        probes(for: Set(Scope.allCases)) + DeepScan.probes()
    }

    /// Quick scan: every available probe in `scopes`. Strictly read-only.
    public static func scan(scopes: Set<Scope> = Set(Scope.allCases)) -> AsyncStream<ScanEvent> {
        stream { probes(for: scopes) }
    }

    /// User-triggered only. Cancel by cancelling the consuming task (or
    /// dropping the stream): the slow loops check it between `du` calls and the
    /// running subprocess is terminated, so it lands within one measurement.
    public static func deepScan() -> AsyncStream<ScanEvent> {
        stream { deepScanProbes() }
    }

    /// Collect a whole scan into the final, severity-sorted report.
    public static func report(_ events: AsyncStream<ScanEvent>) async -> [Finding] {
        var all: [Finding] = []
        for await case let .findings(f) in events { all += f }
        return sorted(all)
    }

    /// Red first; stable within a severity (registry order is kept).
    public static func sorted(_ findings: [Finding]) -> [Finding] {
        findings.enumerated()
            .sorted { ($0.element.severity, $0.offset) < ($1.element.severity, $1.offset) }
            .map(\.element)
    }

    static func stream(_ select: @escaping @Sendable () -> [Probe]) -> AsyncStream<ScanEvent> {
        AsyncStream { cont in
            let task = Task.detached(priority: .userInitiated) {
                await run(select()) { cont.yield($0) }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Start every probe at once (they run concurrently), then deliver in
    /// registry order so the event stream stays deterministic: a progress
    /// event before waiting on each probe, its findings once it and all
    /// earlier probes are done.
    static func run(_ probes: [Probe], emit: @escaping @Sendable (ScanEvent) -> Void) async {
        let total = probes.count
        guard total > 0 else { return }
        await withTaskGroup(of: (Int, [Finding]).self) { group in
            for (i, p) in probes.enumerated() {
                group.addTask { (i, await p.run()) }
            }
            var done: [Int: [Finding]] = [:]
            var next = 0
            emit(.progress(ScanProgress(probeId: probes[0].id, index: 0, total: total)))
            for await (i, findings) in group {
                if Task.isCancelled { group.cancelAll(); return }
                done[i] = findings
                while let ready = done.removeValue(forKey: next) {
                    emit(.findings(ready))
                    next += 1
                    if next < total {
                        emit(.progress(ScanProgress(probeId: probes[next].id, index: next, total: total)))
                    }
                }
            }
        }
    }
}
