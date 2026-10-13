import Foundation

// ollama_models: saved local models WITHOUT waking the daemon. Reads manifest
// files directly (`ollama list` auto-starts the server — the watchman lesson).
// Sizes come from the manifests; blobs are deduped across models, so shared
// bytes are reported honestly instead of double-counted. One finding per model
// with a Delete fix: deletion runs `ollama rm` (it refcounts shared blobs; we
// never touch blobs ourselves) and may start the daemon — acceptable on an
// explicit user click, never during a scan.
public enum OllamaProbe {
    public static let models = Probe(id: "ollama_models", scope: .disk,
                                     available: { DoctorSupport.isDir(manifestsDir) }) { await runModels() }

    static let staleDays: UInt64 = 90

    /// ~/.ollama/models/{manifests,blobs} — ollama's own store layout.
    private static var modelsRoot: URL { Paths.home.appendingPathComponent(".ollama/models", isDirectory: true) }
    static var manifestsDir: URL { modelsRoot.appendingPathComponent("manifests", isDirectory: true) }

    struct Blob: Equatable { var digest: String; var size: UInt64 }

    struct ModelInfo {
        var name: String
        var digests: [Blob]
        var pulledEpoch: UInt64
        /// Last READ of the weights blob (atime) — a much better "last used"
        /// signal than the pull date. Approximate (APFS updates atime lazily); 0 when unknown.
        var lastUsedEpoch: UInt64
        /// Weights blob currently open by some process (read-only lsof).
        var inUse: Bool
    }

    /// blobs/sha256-<hex> for a manifest digest ("sha256:<hex>").
    static func blobPath(_ digest: String) -> URL {
        modelsRoot.appendingPathComponent("blobs/" + digest.replacingOccurrences(of: ":", with: "-"))
    }

    /// stat() only — never opens the blob, so atime itself is not disturbed.
    static func blobAtimeEpoch(_ digest: String) -> UInt64 {
        var st = stat()
        guard stat(blobPath(digest).path, &st) == 0, st.st_atimespec.tv_sec > 0 else { return 0 }
        return UInt64(st.st_atimespec.tv_sec)
    }

    /// Is any process holding the blob open? `lsof -t <file>` is read-only and
    /// file-scoped — it cannot start a daemon.
    static func blobInUse(_ digest: String) async -> Bool {
        guard let r = try? await Proc.run("lsof", ["-t", blobPath(digest).path]) else { return false }
        return r.ok && !r.stdout.isEmpty
    }

    /// The weights layer = the largest blob the manifest references.
    static func weightsDigest(_ digests: [Blob]) -> String? {
        digests.max { $0.size < $1.size }?.digest
    }

    /// OCI-style manifest → every referenced blob. Unrecognized shape → nil
    /// (the model is skipped, never guessed).
    static func parseManifest(_ raw: String) -> [Blob]? {
        guard let v = DoctorSupport.jsonObject(raw) else { return nil }
        func blob(_ item: Any?) -> Blob? {
            guard let o = item as? [String: Any], let d = o["digest"] as? String,
                  let s = DoctorSupport.jsonUInt(o["size"]) else { return nil }
            return Blob(digest: d, size: s)
        }
        guard let config = blob(v["config"]), let layers = v["layers"] as? [Any] else { return nil }
        var out = [config]
        for layer in layers {
            guard let b = blob(layer) else { return nil }
            out.append(b)
        }
        return out
    }

    /// Walk manifests/<registry>/<namespace>/<model>/<tag> files.
    static func scanModels() async -> [ModelInfo] {
        var models: [ModelInfo] = []
        var stack: [(URL, Int)] = [(manifestsDir, 0)]
        while let (dir, depth) = stack.popLast() {
            for path in DoctorSupport.children(dir) {
                let name = path.lastPathComponent
                if name.hasPrefix(".") { continue } // .DS_Store and friends
                if DoctorSupport.isDir(path) {
                    stack.append((path, depth + 1))
                } else if depth >= 3,
                          let raw = try? String(contentsOf: path, encoding: .utf8),
                          let digests = parseManifest(raw) {
                    let weights = weightsDigest(digests)
                    var inUse = false
                    if let weights { inUse = await blobInUse(weights) }
                    models.append(ModelInfo(
                        name: "\(dir.lastPathComponent):\(name)",
                        digests: digests,
                        pulledEpoch: DoctorSupport.mtimeEpoch(path) ?? 0,
                        lastUsedEpoch: weights.map(blobAtimeEpoch) ?? 0,
                        inUse: inUse))
                }
            }
        }
        return models.sorted { $0.name < $1.name }
    }

    struct PerModel {
        var name: String
        var bytes: UInt64
        var ageDays: UInt64
        var stale: Bool
        var lastUsedEpoch: UInt64
        var pulledEpoch: UInt64
        var inUse: Bool
    }

    struct ModelStats {
        var totalBytes: UInt64
        var sharedBytes: UInt64
        var models: [PerModel]
    }

    /// Blob-dedupe across models: total = unique blob bytes; shared = bytes
    /// that more than one model references (counted once).
    static func stats(_ models: [ModelInfo], now: UInt64) -> ModelStats {
        var refcount: [String: (size: UInt64, n: Int)] = [:]
        for m in models {
            for b in m.digests { refcount[b.digest, default: (b.size, 0)].n += 1 }
        }
        let total = refcount.values.reduce(0) { $0 + $1.size }
        let shared = refcount.values.filter { $0.n > 1 }.reduce(0) { $0 + $1.size }
        let per = models.map { m -> PerModel in
            let unique = Set(m.digests.map(\.digest))
            let bytes = unique.compactMap { refcount[$0]?.size }.reduce(0, +)
            // Staleness keys off LAST USE (atime), falling back to pull date.
            let reference = m.lastUsedEpoch > 0 ? m.lastUsedEpoch : m.pulledEpoch
            let age = (now > reference ? now - reference : 0) / 86_400
            return PerModel(name: m.name, bytes: bytes, ageDays: age, stale: age > staleDays && !m.inUse,
                            lastUsedEpoch: m.lastUsedEpoch, pulledEpoch: m.pulledEpoch, inUse: m.inUse)
        }
        return ModelStats(totalBytes: total, sharedBytes: shared, models: per)
    }

    /// One overview line + one row PER MODEL, each with a Delete fix.
    static func runModels() async -> [Finding] {
        let scanned = await scanModels()
        if scanned.isEmpty { return [] } // installed but no models → nothing to report
        let s = stats(scanned, now: DoctorSupport.nowEpoch)
        let p = models
        // The overview carries the worst child severity — a stale model must
        // not hide behind a green summary once rows nest inside this card.
        let anyStale = s.models.contains { $0.stale }
        let plural = s.models.count == 1 ? "" : "s"
        let shared = s.sharedBytes > 0 ? " (\(gb(s.sharedBytes)) shared)" : ""
        var out = [Finding(
            probeId: p.id, scope: p.scope, severity: anyStale ? .yellow : .green, tag: .storage,
            summary: "\(s.models.count) ollama model\(plural) · \(gb(s.totalBytes))\(shared)",
            explain: "Measured from manifests without waking the daemon; layers shared between models are counted "
                + "once. Each model below can be deleted individually.")]
        for m in s.models {
            let lastUsed = m.inUse ? "in use right now"
                : m.lastUsedEpoch > 0 ? "last used \(DoctorSupport.ago(m.lastUsedEpoch))"
                : "never used since pull"
            out.append(Finding(
                probeId: p.id, scope: p.scope, severity: m.stale ? .yellow : .green, tag: .storage,
                summary: "\(m.name) · \(gb(m.bytes)) · \(lastUsed)\(m.stale ? " — \(m.ageDays)d idle" : "")",
                explain: "Pulled \(DoctorSupport.formatDate(m.pulledEpoch)) (\(DoctorSupport.ago(m.pulledEpoch))). "
                    + "\"Last used\" is when the weights were last read from disk (approximate). Deleting frees up "
                    + "to \(gb(m.bytes)) — layers shared with other models survive, `ollama rm` refcounts them "
                    + "safely. Before deleting, check nothing references this model in project configs or eval "
                    + "scripts."
                    + (m.inUse ? " A process is holding this model open right now, so no delete is offered." : ""),
                // No delete while something has the model loaded.
                fix: m.inUse ? nil : "ollama_rm:\(m.name)"))
        }
        return out
    }

    /// Native-confirm copy for a model delete.
    static func fixConfirmation(_ model: String) -> (title: String, message: String) {
        ("Delete \(model)?",
         "Runs `ollama rm` — layers shared with other models are kept. Re-pulling the model downloads it again.")
    }

    /// Delete via `ollama rm`. The name is validated against the ACTUAL
    /// installed set first — the UI string is never trusted, and blobs are
    /// never touched by hand.
    static func deleteModel(_ model: String) async throws -> String {
        guard await scanModels().contains(where: { $0.name == model }) else {
            throw AppError.notFound("no such model: \(model)")
        }
        let r = try await Proc.run("ollama", ["rm", model])
        guard r.ok else { throw AppError.shell(r.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
        Journal.write(action: "ollamaRm", ["model": model])
        return "Deleted \(model) — shared layers (if any) were kept for other models"
    }

    /// Decimal GB/MB — what `ollama` itself prints.
    static func gb(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1e9
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(bytes) / 1e6)
    }
}
