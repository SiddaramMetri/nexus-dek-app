import Foundation

// Deep scan: the slow sweep, ONLY ever user-triggered (never part of the
// quick scan). Two probes:
//   node_modules_sweep — top-level node_modules classified by project activity:
//     Dead (in Downloads / project untouched >6 months) · Stale (>30 days) ·
//     Active (locked — no delete is ever offered).
//   dev_caches — safe regenerable caches get a one-click fix; caution items
//     (the live pnpm store) and gated items (Docker) are guide-only;
//     never-touch items are not listed at all.
// Sizes via `du -sk`; deletes re-scan at fix time and are journaled.
// Cancellation is Swift task cancellation: the loops check it between `du`
// calls and a cancel also terminates the running `du`/`find`.
public enum DeepScan {
    public static let nodeModulesSweep = Probe(id: "node_modules_sweep", scope: .disk) { await runNodeModules() }
    public static let devCaches = Probe(id: "dev_caches", scope: .disk) { await runDevCaches() }

    public static let registry = [nodeModulesSweep, devCaches]

    /// Deep probes that apply on this machine.
    public static func probes() -> [Probe] { registry.filter { $0.available() } }

    // MARK: - node_modules sweep

    static let deadDays: UInt64 = 180
    static let staleDays: UInt64 = 30
    static let maxNamed = 8

    enum Class: String { case dead = "Dead", stale = "Stale", active = "Active" }

    static func classify(inDownloads: Bool, projectAgeDays: UInt64) -> Class {
        if inDownloads || projectAgeDays > deadDays { return .dead }
        return projectAgeDays > staleDays ? .stale : .active
    }

    private static var downloads: URL { Paths.home.appendingPathComponent("Downloads", isDirectory: true) }

    /// `find` arguments for top-level node_modules under $HOME — bounded depth,
    /// prunes Library / Trash / dotdirs / the media folders, never descends
    /// INTO a node_modules. Music, Pictures and Movies are pruned for a second
    /// reason: walking them pops a TCC prompt each (Media Library, Photos).
    static func findArgs(home h: String) -> [String] {
        [h, "-maxdepth", "6",
         "(", "-path", "\(h)/Library", "-o", "-path", "\(h)/.Trash", "-o", "-path", "\(h)/Music",
         "-o", "-path", "\(h)/Pictures", "-o", "-path", "\(h)/Movies", "-o", "-name", ".*", ")",
         "-prune", "-o", "-type", "d", "-name", "node_modules", "-print", "-prune"]
    }

    static func findNodeModules() async -> [URL] {
        let out = await Proc.anyOutput("find", findArgs(home: Paths.home.path))
        return out.split(whereSeparator: \.isNewline).map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }

    /// Project activity = newest top-level entry mtime in the project dir
    /// (excluding node_modules itself) — cheap and good enough to classify.
    static func projectAgeDays(_ project: URL, now: UInt64) -> UInt64 {
        let newest = DoctorSupport.children(project)
            .filter { $0.lastPathComponent != "node_modules" }
            .compactMap(DoctorSupport.mtimeEpoch)
            .max() ?? 0
        return (now > newest ? now - newest : 0) / 86_400
    }

    struct Bucket {
        var count = 0
        var bytes: UInt64 = 0
        var names: [String] = []

        mutating func add(_ project: URL, _ bytes: UInt64) {
            count += 1
            self.bytes += bytes
            names.append(project.lastPathComponent)
        }

        var named: String {
            var s = names.prefix(maxNamed).joined(separator: ", ")
            if names.count > maxNamed { s += ", … +\(names.count - maxNamed)" }
            return s
        }
    }

    static func classOf(_ nm: URL, now: UInt64) -> Class {
        let project = nm.deletingLastPathComponent()
        return classify(inDownloads: DoctorSupport.path(project, isInside: downloads),
                        projectAgeDays: projectAgeDays(project, now: now))
    }

    static func sweep() async -> (dead: Bucket, stale: Bucket, active: Bucket) {
        let now = DoctorSupport.nowEpoch
        var dead = Bucket(), stale = Bucket(), active = Bucket()
        for nm in await findNodeModules() {
            if Task.isCancelled { break }
            let project = nm.deletingLastPathComponent()
            let cls = classOf(nm, now: now)
            let bytes = await DoctorSupport.duBytes(nm)
            switch cls {
            case .dead: dead.add(project, bytes)
            case .stale: stale.add(project, bytes)
            case .active: active.add(project, bytes)
            }
        }
        return (dead, stale, active)
    }

    static func runNodeModules() async -> [Finding] {
        let (dead, stale, active) = await sweep()
        let id = nodeModulesSweep.id
        var out: [Finding] = []
        if dead.count > 0 {
            out.append(Finding(
                probeId: id, scope: .disk, severity: .yellow, tag: .storage,
                summary: "\(dead.count) dead node_modules · \(DoctorSupport.mb(dead.bytes)) (Downloads / untouched >6 months)",
                explain: "Projects: \(dead.named). Nothing has touched these in months (or they live in Downloads) — "
                    + "deleting is safe, they regenerate on the next install.",
                fix: "deep_dead_node_modules"))
        }
        if stale.count > 0 {
            out.append(Finding(
                probeId: id, scope: .disk, severity: .yellow, tag: .storage,
                summary: "\(stale.count) stale node_modules · \(DoctorSupport.mb(stale.bytes)) (untouched 1–6 months)",
                explain: "Projects: \(stale.named). Might still be in rotation — delete only if you're not coming "
                    + "back soon; an install brings them back.",
                fix: "deep_stale_node_modules"))
        }
        out.append(Finding(
            probeId: id, scope: .disk, severity: .green, tag: .storage,
            summary: active.count > 0
                ? "\(active.count) active node_modules · \(DoctorSupport.mb(active.bytes)) (locked — never offered for deletion)"
                : "No active node_modules",
            explain: "Projects touched within the last month keep their dependencies."))
        return out
    }

    // MARK: - dev caches

    /// Only worth a line above this — below it, silence beats noise.
    static let cacheMinBytes: UInt64 = 100 * 1024 * 1024

    struct SafeCache { let fixId: String, label: String, rel: String }

    /// Safe = regenerates on demand; one-click fix. (Never-touch items —
    /// ollama blobs, anaconda, ~/.cache/prisma — are deliberately NOT here.)
    static let safeCaches: [SafeCache] = [
        SafeCache(fixId: "cache_npm", label: "npm cache", rel: ".npm/_cacache"),
        SafeCache(fixId: "cache_uv", label: "uv cache", rel: ".cache/uv"),
        SafeCache(fixId: "cache_huggingface", label: "Hugging Face cache", rel: ".cache/huggingface"),
        SafeCache(fixId: "cache_puppeteer", label: "Puppeteer browsers", rel: ".cache/puppeteer"),
        SafeCache(fixId: "cache_gradle", label: "Gradle caches", rel: ".gradle/caches"),
        SafeCache(fixId: "cache_deriveddata", label: "Xcode DerivedData", rel: "Library/Developer/Xcode/DerivedData"),
    ]

    static func cachePath(_ rel: String) -> URL { Paths.home.appendingPathComponent(rel, isDirectory: true) }

    private static var pnpmStoreRoot: URL { cachePath("Library/pnpm/store") }
    private static var dockerData: URL { cachePath("Library/Containers/com.docker.docker") }

    static func runDevCaches() async -> [Finding] {
        var out: [Finding] = []
        for c in safeCaches {
            if Task.isCancelled { break }
            let path = cachePath(c.rel)
            guard DoctorSupport.isDir(path) else { continue }
            let bytes = await DoctorSupport.duBytes(path)
            guard bytes >= cacheMinBytes else { continue }
            out.append(Finding(
                probeId: devCaches.id, scope: .disk, severity: .yellow, tag: .storage,
                summary: "\(c.label) · \(DoctorSupport.mb(bytes)) reclaimable",
                explain: "Pure cache — the tool rebuilds it on demand. Clearing frees disk but does NOT make the "
                    + "machine faster, and the next run repopulates it.",
                fix: c.fixId))
        }
        // pnpm: the LIVE store is caution-only (hardlinked, prune-by-hand), but
        // a store version pnpm has moved off is a plain orphan — one-click.
        if !Task.isCancelled, DoctorSupport.isDir(pnpmStoreRoot) {
            let scan = await scanPnpmStores()
            if scan.orphanBytes >= cacheMinBytes {
                out.append(Finding(
                    probeId: devCaches.id, scope: .disk, severity: .yellow, tag: .storage,
                    summary: "pnpm store \(scan.orphanNames) · \(DoctorSupport.mb(scan.orphanBytes)) orphaned",
                    explain: "pnpm changed its store format and left this behind — it now uses \(scan.activeName), "
                        + "and `pnpm store prune` only ever touches the current one, so this folder can never shrink "
                        + "no matter how often you prune it. Nothing links into it any more; a package that's "
                        + "needed again is downloaded once.",
                    fix: "pnpm_orphan_stores"))
            }
            // The live store stays guide-only — its files are hardlinked into
            // every project's node_modules, so only pnpm may decide.
            if scan.activeBytes >= cacheMinBytes {
                out.append(guideFinding(
                    "pnpm store · \(DoctorSupport.mb(scan.activeBytes))",
                    "pnpm hardlinks every project's packages out of this store — deleting it raw breaks those "
                        + "projects. Prune only removes packages nothing references.",
                    ["In this app's Terminal (or any shell): pnpm store prune"]))
            }
        }
        if !Task.isCancelled, DoctorSupport.isDir(dockerData) {
            out.append(guideFinding(
                "Docker data · \(DoctorSupport.mb(await DoctorSupport.duBytes(dockerData)))",
                "Lives in ~/Library/Containers/com.docker.docker (Docker.raw is the big file). Volumes may hold "
                    + "real data, so this is gated — never one-click.",
                ["In this app's Terminal: docker system df -v — volumes must be empty or expendable",
                 "Then: docker system prune -a (images/containers), or uninstall Docker Desktop entirely if unused",
                 "Docker Desktop → Settings → Resources → Disk can also shrink Docker.raw"]))
        }
        if out.isEmpty {
            out.append(Finding(probeId: devCaches.id, scope: .disk, severity: .green, tag: .storage,
                               summary: "No significant dev caches", explain: "Nothing above the 100 MB noise floor."))
        }
        return out
    }

    static func guideFinding(_ name: String, _ explain: String, _ steps: [String]) -> Finding {
        Finding(probeId: devCaches.id, scope: .disk, severity: .yellow, tag: .storage,
                summary: "\(name) present — manual cleanup only", explain: explain, guide: steps)
    }

    // MARK: - pnpm store versions

    struct PnpmStores {
        /// Store-version dirs pnpm no longer uses, e.g. `~/Library/pnpm/store/v10`.
        var orphans: [URL] = []
        var orphanBytes: UInt64 = 0
        var active: URL?
        var activeBytes: UInt64 = 0

        var orphanNames: String { orphans.map(\.lastPathComponent).joined(separator: ", ") }
        var activeName: String { active?.lastPathComponent ?? "another folder" }
    }

    /// A store-version dir pnpm has moved off. `active` is the *name* pnpm
    /// reports (`v11`) — names, not paths, because `pnpm store path` can come
    /// back through an equivalent prefix (`/private/…`, a symlinked home) and a
    /// path compare would mark the LIVE store as an orphan. nil = couldn't ask
    /// pnpm → nothing is an orphan (fail closed: this decides a multi-GB delete).
    static func isOrphanStore(_ name: String, active: String?) -> Bool {
        guard let active, name != active, name.hasPrefix("v") else { return false }
        let digits = name.dropFirst()
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The version dir pnpm is using right now — its own answer is the only
    /// authority; guessing "highest vN" would eventually delete the live store.
    static func pnpmActiveStore() async -> URL? {
        guard let out = await Proc.output("pnpm", ["store", "path"]) else { return nil }
        let url = URL(fileURLWithPath: out.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
        return DoctorSupport.isDir(url) ? url : nil
    }

    static func scanPnpmStores() async -> PnpmStores {
        var s = PnpmStores()
        s.active = await pnpmActiveStore()
        let activeName = s.active?.lastPathComponent
        for dir in DoctorSupport.children(pnpmStoreRoot)
        where DoctorSupport.isDir(dir) && isOrphanStore(dir.lastPathComponent, active: activeName) {
            s.orphanBytes += await DoctorSupport.duBytes(dir)
            s.orphans.append(dir)
        }
        if let active = s.active { s.activeBytes = await DoctorSupport.duBytes(active) }
        return s
    }

    /// Re-scans at fix time (never trusts a stale finding) and refuses anything
    /// that isn't a direct child of the store root.
    static func deletePnpmOrphanStores() async throws -> String {
        let scan = await scanPnpmStores()
        if scan.orphans.isEmpty { return "No orphaned pnpm stores." }
        var removed = 0, freed: UInt64 = 0
        let root = pnpmStoreRoot.standardizedFileURL.path
        for dir in scan.orphans where dir.deletingLastPathComponent().standardizedFileURL.path == root {
            let bytes = await DoctorSupport.duBytes(dir)
            if (try? FileManager.default.removeItem(at: dir)) != nil {
                removed += 1
                freed += bytes
            }
        }
        Journal.write(action: "deletePnpmOrphanStores", ["removed": removed, "freedBytes": freed])
        return "Removed \(removed) orphaned pnpm store\(removed == 1 ? "" : "s") · freed \(DoctorSupport.mb(freed))"
    }

    // MARK: - Fixes

    /// Native-confirm copy for each destructive fix id — nil means the id is
    /// unknown (`fix` rejects it) or needs no confirm.
    static func fixConfirmation(_ fixId: String) async -> (title: String, message: String)? {
        switch fixId {
        case "deep_dead_node_modules":
            return ("Delete dead node_modules?",
                    "Their projects are gone or untouched for months — they regenerate on the next install.")
        case "deep_stale_node_modules":
            return ("Delete stale node_modules?",
                    "These projects were untouched for 1–6 months — an install brings the dependencies back.")
        case "pnpm_orphan_stores":
            // Re-scanned so the sheet shows what will actually go, not a number
            // the finding remembered minutes ago.
            let scan = await scanPnpmStores()
            let n = scan.orphans.count
            return ("Delete \(n) orphaned pnpm store\(n == 1 ? "" : "s")?",
                    "\(scan.orphanNames) · \(DoctorSupport.mb(scan.orphanBytes)). pnpm uses \(scan.activeName) now "
                        + "and can never prune these. Nothing links into them — packages that are needed again are "
                        + "downloaded once.")
        default:
            return safeCaches.first { $0.fixId == fixId }.map {
                ("Clear \($0.label)?",
                 "Pure cache — it regenerates on demand. This frees disk but does not make the machine faster.")
            }
        }
    }

    /// Strict whitelist — the UI can never name a path, only one of these ids.
    /// Callers confirm first (see `DoctorFix.run`).
    static func fix(_ fixId: String) async throws -> String {
        switch fixId {
        case "deep_dead_node_modules": return try await deleteNodeModules(.dead)
        case "deep_stale_node_modules": return try await deleteNodeModules(.stale)
        case "pnpm_orphan_stores": return try await deletePnpmOrphanStores()
        default:
            guard let c = safeCaches.first(where: { $0.fixId == fixId }) else {
                throw AppError.invalidName("unknown fix: \(fixId)")
            }
            return try await deleteCache(c)
        }
    }

    /// Re-scans at fix time, deletes only the requested class, journals,
    /// reports freed bytes.
    static func deleteNodeModules(_ cls: Class) async throws -> String {
        let now = DoctorSupport.nowEpoch
        var removed = 0, freed: UInt64 = 0
        for nm in await findNodeModules() where classOf(nm, now: now) == cls {
            let bytes = await DoctorSupport.duBytes(nm)
            if (try? FileManager.default.removeItem(at: nm)) != nil {
                removed += 1
                freed += bytes
            }
        }
        Journal.write(action: "deleteNodeModules", ["class": cls.rawValue, "removed": removed, "freedBytes": freed])
        return "Removed \(removed) node_modules · freed \(DoctorSupport.mb(freed)) — they regenerate on the next install"
    }

    static func deleteCache(_ c: SafeCache) async throws -> String {
        let path = cachePath(c.rel)
        guard DoctorSupport.isDir(path) else { return "\(c.label) is already empty." }
        let bytes = await DoctorSupport.duBytes(path)
        do { try FileManager.default.removeItem(at: path) } catch { throw AppError.io(error.localizedDescription) }
        Journal.write(action: "clearCache", ["cache": c.label, "freedBytes": bytes])
        return "Cleared \(c.label) · freed \(DoctorSupport.mb(bytes)) — it regenerates on demand"
    }
}
