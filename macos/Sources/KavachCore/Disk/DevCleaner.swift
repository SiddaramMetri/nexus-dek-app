import Foundation

/// One removable dev folder found under the home folder.
public struct JunkItem: Identifiable, Equatable, Codable, Sendable {
    public enum Category: String, Codable, Sendable, CaseIterable {
        /// In Downloads, or the project is untouched for over 6 months.
        case dead
        /// Project untouched 1–6 months.
        case stale
        /// Project touched within the last month.
        case active
    }

    public var id: String { path }
    /// Absolute path of the folder that would be removed.
    public let path: String
    public let kind: JunkKind
    /// The repository / workspace this folder belongs to — the unit the UI
    /// groups by (`rideorbit` for `rideorbit/web/node_modules`).
    public let groupRoot: String
    /// The project folder that owns it.
    public var project: String { (path as NSString).deletingLastPathComponent }
    public var projectName: String { (project as NSString).lastPathComponent }
    public var folderName: String { (path as NSString).lastPathComponent }
    /// Newest top-level change in the project (excluding junk folders); 0 = unknown.
    public let lastUsedEpoch: UInt64
    public let category: Category
    /// Project touched within `DevCleaner.lockDays` — never deletable.
    public let locked: Bool
    /// nil until `du` has measured it.
    public var bytes: UInt64?
    /// Why this folder must be kept even though it's old (`locked` is set too),
    /// e.g. a venv whose packages are listed nowhere.
    public var keepReason: String? = nil
    /// Deletable, but worth knowing first (no lockfile → versions may change).
    public var warning: String? = nil
}

/// The dev cleaner: lists node_modules and other regenerable dev folders under
/// $HOME with sizes and project activity, and moves chosen ones to the Trash.
/// Only the listed folder is ever removed — never the project, its source,
/// manifests or lockfiles. Age rules are the Doctor deep scan's (`DeepScan`).
public enum DevCleaner {
    /// Projects touched this recently are locked: no delete is offered.
    public static let lockDays: UInt64 = 7
    static let sizeConcurrency = 8

    public enum Event: Sendable, Equatable {
        /// `find` finished: every folder, unmeasured, classified.
        case found([JunkItem])
        case sized(id: String, bytes: UInt64)
    }

    // MARK: - Saved scan

    /// The last finished scan, so the tab opens with results instead of empty.
    public struct SavedScan: Codable, Sendable {
        public var items: [JunkItem]
        public var scannedAt: Double
    }

    static let saved = JSONStore<SavedScan>(file: "cleanup.json", key: "lastScan")

    public static func save(_ items: [JunkItem]) {
        saved.save(SavedScan(items: items, scannedAt: Date().timeIntervalSince1970))
    }

    /// The saved scan, re-checked: folders that are gone are dropped, and age,
    /// locks and safety notes are recomputed now (only sizes come from the save).
    public static func restore(home: URL = Paths.home) async -> (items: [JunkItem], scannedAt: Date)? {
        guard let scan = saved.load(), !scan.items.isEmpty else { return nil }
        let now = DoctorSupport.nowEpoch
        let items: [JunkItem] = scan.items.compactMap { old in
            guard var fresh = item(for: URL(fileURLWithPath: old.path, isDirectory: true), now: now, home: home) else { return nil }
            fresh.bytes = old.bytes
            return fresh
        }
        return (items, Date(timeIntervalSince1970: scan.scannedAt))
    }

    // MARK: - Scan

    /// `find` over $HOME (bounded depth): prunes Library / Trash / media folders,
    /// prints and prunes every candidate folder name, and prunes other hidden
    /// folders. Music, Pictures and Movies would each pop a privacy prompt.
    static func findArgs(home h: String) -> [String] {
        var names: [String] = ["("]
        for (i, n) in JunkKind.allFolderNames.enumerated() {
            if i > 0 { names.append("-o") }
            names += ["-name", n]
        }
        names.append(")")
        return [h, "-maxdepth", "7",
                "(", "-path", "\(h)/Library", "-o", "-path", "\(h)/.Trash", "-o", "-path", "\(h)/Music",
                "-o", "-path", "\(h)/Pictures", "-o", "-path", "\(h)/Movies", ")", "-prune",
                "-o", "-type", "d"] + names + ["-print", "-prune",
                "-o", "-name", ".*", "-prune"]
    }

    static func findCandidates(home: URL = Paths.home) async -> [URL] {
        let out = await Proc.anyOutput("find", findArgs(home: home.path))
        return out.split(whereSeparator: \.isNewline).map { URL(fileURLWithPath: String($0), isDirectory: true) }
    }

    /// Streams discovery first, then each folder's size as `du` finishes.
    /// Read-only. Cancelling the consuming task stops `find`/`du`.
    public static func scan() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                let now = DoctorSupport.nowEpoch
                let items = await findCandidates().compactMap { item(for: $0, now: now) }
                    .sorted { order($0) < order($1) }
                continuation.yield(.found(items))
                await withTaskGroup(of: (String, UInt64).self) { group in
                    var next = 0
                    func addNext() {
                        guard next < items.count else { return }
                        let url = URL(fileURLWithPath: items[next].path, isDirectory: true)
                        let id = items[next].id
                        next += 1
                        group.addTask { (id, await DoctorSupport.duBytes(url)) }
                    }
                    for _ in 0..<sizeConcurrency { addNext() }
                    for await (id, bytes) in group {
                        if Task.isCancelled { group.cancelAll(); break }
                        continuation.yield(.sized(id: id, bytes: bytes))
                        addNext()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func order(_ i: JunkItem) -> (Int, String) {
        let rank = switch i.category { case .dead: 0; case .stale: 1; case .active: 2 }
        return (rank, i.path)
    }

    /// nil when the folder isn't provably junk (see `JunkKind.matches`).
    static func item(for dir: URL, now: UInt64, home: URL = Paths.home) -> JunkItem? {
        guard let kind = JunkKind.kind(forFolderName: dir.lastPathComponent), kind.matches(dir) else { return nil }
        let project = dir.deletingLastPathComponent()
        let newest = lastUsedEpoch(project)
        let ageDays = (now > newest ? now - newest : 0) / 86_400
        let inDownloads = DoctorSupport.path(project, isInside: home.appendingPathComponent("Downloads", isDirectory: true))
        let cls: JunkItem.Category = switch DeepScan.classify(inDownloads: inDownloads, projectAgeDays: ageDays) {
        case .dead: .dead
        case .stale: .stale
        case .active: .active
        }
        let root = JunkGrouping.root(forProject: project, home: home)
        var keep: String?
        var warning: String?
        switch kind {
        case .pythonVenv where !JunkKind.hasPythonManifest(project):
            keep = "No requirements.txt or pyproject.toml here — these packages couldn't be reinstalled"
        case .nodeModules where !JunkKind.hasJSLockfile(project, upTo: root):
            warning = "No lockfile — a reinstall may pick newer package versions"
        default: break
        }
        let recent = newest > 0 && ageDays < lockDays
        return JunkItem(path: dir.path, kind: kind, groupRoot: root.path, lastUsedEpoch: newest, category: cls,
                        locked: recent || keep != nil, bytes: nil, keepReason: keep, warning: warning)
    }

    /// Newest top-level mtime in the project, ignoring the junk folders
    /// themselves (a build writing into `dist` doesn't make a project "used").
    static func lastUsedEpoch(_ project: URL) -> UInt64 {
        let junk = Set(JunkKind.allFolderNames)
        return DoctorSupport.children(project)
            .filter { !junk.contains($0.lastPathComponent) }
            .compactMap(DoctorSupport.mtimeEpoch)
            .max() ?? 0
    }

    // MARK: - Delete

    public struct TrashResult: Equatable, Sendable {
        /// Paths moved to the Trash.
        public var removed: [String]
        public var freedBytes: UInt64
        /// Paths refused at delete time (moved, locked since the scan, failed check, …).
        public var skipped: [String]
    }

    /// Confirm natively, then move each folder to the Trash (recoverable).
    /// Every path is re-validated at delete time — the UI only proposes paths.
    public static func moveToTrash(_ items: [JunkItem], confirmer: Confirmer) async throws -> TrashResult {
        let candidates = items.filter { !$0.locked }
        guard !candidates.isEmpty else { return TrashResult(removed: [], freedBytes: 0, skipped: []) }
        let bytes = candidates.compactMap(\.bytes).reduce(0, +)
        // Unsaved-work check runs right before the confirm, so it's current.
        let git = await GitSafety.statuses(Array(Set(candidates.map(\.groupRoot))))
        try await confirmer.require(
            title: "Move \(candidates.count) folder\(candidates.count == 1 ? "" : "s") to the Trash?",
            message: confirmMessage(candidates, bytes: bytes) + gitWarning(git),
            action: "Move to Trash", destructive: true)
        let result = await trash(candidates.map(\.path)) { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        Journal.write(action: "trashDevFolders", [
            "removed": result.removed.count, "freedBytes": result.freedBytes, "skipped": result.skipped.count,
        ])
        return result
    }

    static func confirmMessage(_ items: [JunkItem], bytes: UInt64) -> String {
        let names = items.map { "\($0.projectName)/\($0.folderName)" }
        var list = names.prefix(8).joined(separator: ", ")
        if names.count > 8 { list += " +\(names.count - 8) more" }
        let kinds = Set(items.map(\.kind))
        let howBack = JunkKind.allCases.filter(kinds.contains).map(\.regenerate).joined(separator: " · ")
        return "\(Format.bytes(bytes)) from: \(list).\n\n"
            + "Only these folders are removed — your source code, package.json and lockfiles stay. "
            + "They go to the Trash, so you can put them back, and they regenerate with: \(howBack)."
    }

    /// Extra confirm paragraph naming projects with uncommitted or unpushed work.
    static func gitWarning(_ statuses: [String: GitSafety.Status]) -> String {
        let risky = statuses.filter { $0.value.hasUnsavedWork }.sorted { $0.key < $1.key }
        guard !risky.isEmpty else { return "" }
        let lines = risky.prefix(6).map { "• \(($0.key as NSString).lastPathComponent): \($0.value.summary)" }
        let more = risky.count > 6 ? "\n• +\(risky.count - 6) more" : ""
        return "\n\nHeads-up — unsaved git work (your code is not touched by this, but it isn't backed up either):\n"
            + lines.joined(separator: "\n") + more
    }

    /// Testable core: validate, measure, remove. `remove` is injected so tests
    /// never touch the real Trash.
    static func trash(
        _ paths: [String], home: URL = Paths.home, now: UInt64 = DoctorSupport.nowEpoch,
        remove: (URL) throws -> Void
    ) async -> TrashResult {
        var result = TrashResult(removed: [], freedBytes: 0, skipped: [])
        for path in paths {
            guard let url = validated(path, home: home, now: now) else {
                result.skipped.append(path)
                continue
            }
            let bytes = await DoctorSupport.duBytes(url)
            do {
                try remove(url)
                result.removed.append(path)
                result.freedBytes += bytes
            } catch {
                result.skipped.append(path)
            }
        }
        return result
    }

    /// Deletable only if it is a real (non-symlink) directory, strictly inside
    /// home but outside Library, still provably junk for its kind, and its
    /// project isn't locked — all re-checked now, not trusted from the scan.
    static func validated(_ path: String, home: URL, now: UInt64) -> URL? {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard url.standardizedFileURL.path != home.standardizedFileURL.path,
              DoctorSupport.path(url, isInside: home),
              !DoctorSupport.path(url, isInside: home.appendingPathComponent("Library", isDirectory: true)),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let fresh = item(for: url, now: now, home: home), !fresh.locked
        else { return nil }
        return url
    }

    /// After a delete: which of `paths` are really gone from where they were.
    public static func verifyGone(_ paths: [String]) -> (gone: [String], stillThere: [String]) {
        let fm = FileManager.default
        var gone: [String] = [], still: [String] = []
        for p in paths {
            if fm.fileExists(atPath: p) { still.append(p) } else { gone.append(p) }
        }
        return (gone, still)
    }
}
