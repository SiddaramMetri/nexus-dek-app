import Foundation
import NexusCore
import Observation

/// State for the Dev cleanup tab. App-wide (like the Doctor scan) so a running
/// scan or a finished list survives switching tabs.
@MainActor @Observable
final class CleanupModel {
    static let shared = CleanupModel()

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", dead = "Dead", stale = "Stale", active = "Active"
        var id: String { rawValue }
        func includes(_ c: JunkItem.Category) -> Bool {
            switch self {
            case .all: true
            case .dead: c == .dead
            case .stale: c == .stale
            case .active: c == .active
            }
        }
    }

    enum GroupSort: String, CaseIterable, Identifiable {
        case size = "Size", lastUsed = "Last used", name = "Name"
        var id: String { rawValue }
    }

    enum TrashPhase: Equatable { case idle, running, done(removed: Int), failed }
    enum VerifyPhase: Equatable { case idle, verified(freed: UInt64), failed(stillThere: Int) }

    var items: [JunkItem] = []
    var scanned = false
    /// When the shown results were measured (a restored scan shows its age).
    var scannedAt: Date?
    private var restoreAttempted = false
    var scanning = false
    var foundDone = false
    var filter: Filter = .all
    var kind: JunkKind? = nil
    var bigOnly = false
    var query = ""
    var sort: GroupSort = .size
    /// Item ids marked for removal (across all projects).
    var selection: Set<String> = []
    /// The project shown on the right.
    var focusedGroup: String?
    var trash: TrashPhase = .idle
    var verify: VerifyPhase = .idle
    /// Bytes this session moved to the Trash (drives the "empty it" hint).
    var trashedBytes: UInt64 = 0
    var emptyingTrash = false
    /// Git status per project root, loaded on demand (nil value = not a repo).
    var git: [String: GitSafety.Status?] = [:]
    var gitLoading: Set<String> = []
    private var scanTask: Task<Void, Never>?

    static let bigThreshold: UInt64 = 500 * 1_048_576

    // MARK: - Derived

    var visibleItems: [JunkItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { i in
            filter.includes(i.category)
                && (kind == nil || i.kind == kind)
                && (!bigOnly || (i.bytes ?? 0) >= Self.bigThreshold)
                && (q.isEmpty || i.path.lowercased().contains(q))
        }
    }

    var groups: [JunkGroup] {
        let g = JunkGrouping.group(visibleItems)
        switch sort {
        case .size: return g
        case .lastUsed: return g.sorted { $0.lastUsedEpoch < $1.lastUsedEpoch }
        case .name: return g.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    var focused: JunkGroup? {
        let all = groups
        return all.first { $0.root == focusedGroup } ?? all.first
    }

    var measuredCount: Int { items.filter { $0.bytes != nil }.count }
    var totalBytes: UInt64 { items.compactMap(\.bytes).reduce(0, +) }
    var projectCount: Int { Set(items.map(\.groupRoot)).count }
    var reclaimableBytes: UInt64 {
        items.filter { !$0.locked && $0.category != .active }.compactMap(\.bytes).reduce(0, +)
    }

    /// Every unlocked folder in a dead project — what "Clean all dead" removes.
    var deadItems: [JunkItem] { items.filter { $0.category == .dead && !$0.locked } }
    var deadProjectCount: Int { Set(deadItems.map(\.groupRoot)).count }

    var selectedItems: [JunkItem] { items.filter { selection.contains($0.id) && !$0.locked } }
    var selectedBytes: UInt64 { selectedItems.compactMap(\.bytes).reduce(0, +) }

    // MARK: - Pipeline

    var steps: [PipelineStep] {
        let n = items.count
        let find: PipelineStep.State = !scanned ? .pending : foundDone ? .done : .running
        let measuring = foundDone && measuredCount < n && scanning
        let measure: PipelineStep.State = !foundDone ? .pending : measuring ? .running : .done
        return [
            PipelineStep(title: "Find", symbol: "magnifyingglass", state: find,
                         detail: !scanned ? "Ready" : foundDone ? "\(n) folders" : "Searching…"),
            PipelineStep(title: "Check", symbol: "checklist", state: find,
                         detail: foundDone ? "\(projectCount) projects" : !scanned ? "—" : "Checking…"),
            PipelineStep(title: "Measure", symbol: "internaldrive", state: measure,
                         detail: !foundDone ? "—" : measuring ? "\(measuredCount)/\(n)" : Format.bytes(totalBytes)),
        ]
    }

    // MARK: - Selection

    enum Mark { case none, some, all }

    func mark(_ g: JunkGroup) -> Mark {
        let ids = g.deletable.map(\.id)
        let n = ids.filter(selection.contains).count
        return n == 0 ? .none : n == ids.count ? .all : .some
    }

    func toggle(_ g: JunkGroup) {
        let ids = Set(g.deletable.map(\.id))
        if mark(g) == .all { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

    func toggle(_ item: JunkItem) {
        guard !item.locked else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    func select(_ categories: Set<JunkItem.Category>) {
        selection = Set(visibleItems.filter { categories.contains($0.category) && !$0.locked }.map(\.id))
    }

    // MARK: - Actions

    /// Loads git status for a project once (cheap, read-only, no network).
    func loadGit(_ root: String) {
        guard git[root] == nil, !gitLoading.contains(root) else { return }
        gitLoading.insert(root)
        Task {
            git[root] = .some(await GitSafety.status(root))
            gitLoading.remove(root)
        }
    }

    /// "Clean all dead": every unlocked folder in dead projects, one confirm.
    func cleanAllDead(model: AppModel) {
        selection = Set(deadItems.map(\.id))
        moveToTrash(deadItems, model: model)
    }

    /// Empties the whole Trash via Finder, after a native confirm.
    func emptyTrash(model: AppModel) {
        guard !emptyingTrash else { return }
        Task {
            let ok = await model.confirmer.confirm(
                title: "Empty the Trash?",
                message: "This permanently deletes everything in the Trash — including anything that was there before, "
                    + "not only the \(Format.bytes(trashedBytes)) moved here. It can't be undone.",
                action: "Empty Trash", destructive: true)
            guard ok else { return }
            emptyingTrash = true
            defer { emptyingTrash = false }
            do {
                let out = try await model.track("Emptying the Trash") {
                    try await Proc.run("osascript", ["-e", "tell application \"Finder\" to empty trash"])
                }
                guard out.ok else { throw AppError.shell(out.err.isEmpty ? "Finder couldn't empty the Trash." : out.err) }
                model.toast("Trash emptied · \(Format.bytes(trashedBytes)) freed")
                trashedBytes = 0
            } catch {
                model.report(error)
            }
        }
    }

    func scan() {
        scanTask?.cancel()
        items = []
        selection = []
        focusedGroup = nil
        git = [:]
        trash = .idle
        verify = .idle
        scanning = true
        scanned = true
        foundDone = false
        scannedAt = nil
        scanTask = Task {
            for await event in DevCleaner.scan() {
                switch event {
                case let .found(list):
                    items = list
                    foundDone = true
                case let .sized(id, bytes):
                    if let i = items.firstIndex(where: { $0.id == id }) { items[i].bytes = bytes }
                }
            }
            scanning = false
            // A complete scan is saved so the next launch opens with results.
            if !Task.isCancelled, items.allSatisfy({ $0.bytes != nil }) {
                scannedAt = Date()
                DevCleaner.save(items)
            }
        }
    }

    /// Opens with the last saved scan (re-checked) instead of an empty tab.
    func restoreIfNeeded() {
        guard !restoreAttempted, !scanned else { return }
        restoreAttempted = true
        Task {
            guard let saved = await DevCleaner.restore(), !scanned else { return }
            items = saved.items
            scannedAt = saved.scannedAt
            scanned = true
            foundDone = true
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanning = false
        if !foundDone { scanned = false }
    }

    func moveToTrash(_ targets: [JunkItem], model: AppModel) {
        let targets = targets.filter { !$0.locked }
        guard !targets.isEmpty, trash != .running else { return }
        verify = .idle
        trash = .running
        Task {
            do {
                let result = try await model.track("Moving \(targets.count) folders to the Trash") {
                    try await DevCleaner.moveToTrash(targets, confirmer: model.confirmer)
                }
                trash = .done(removed: result.removed.count)
                trashedBytes += result.freedBytes
                // Verify: re-check the disk instead of trusting the call.
                let check = DevCleaner.verifyGone(result.removed)
                let gone = Set(check.gone)
                items.removeAll { gone.contains($0.id) }
                selection.subtract(gone)
                verify = check.stillThere.isEmpty ? .verified(freed: result.freedBytes) : .failed(stillThere: check.stillThere.count)
                var msg = "Moved \(check.gone.count) folder\(check.gone.count == 1 ? "" : "s") to the Trash · freed \(Format.bytes(result.freedBytes))"
                if !result.skipped.isEmpty { msg += " · \(result.skipped.count) skipped (changed since the scan)" }
                model.toast(msg, isError: check.gone.isEmpty)
            } catch {
                // A dismissed confirm leaves everything as it was.
                trash = AppError.from(error).isCancelled ? .idle : .failed
                model.report(error)
            }
        }
    }
}
