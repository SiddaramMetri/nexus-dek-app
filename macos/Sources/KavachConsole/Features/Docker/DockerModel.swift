import Foundation
import KavachCore
import Observation

/// State for the Docker tab. App-wide so the last read survives tab switches.
/// Refreshed on appear and by the Refresh button — never polled.
@MainActor @Observable
final class DockerModel {
    static let shared = DockerModel()

    enum Phase: Equatable { case idle, ready, unavailable(DockerUnavailable), failed(AppError) }

    enum Section: String, CaseIterable, Identifiable {
        case images, containers, volumes, buildCache
        var id: String { rawValue }
        var label: String {
            switch self {
            case .images: "Images"
            case .containers: "Containers"
            case .volumes: "Volumes"
            case .buildCache: "Build cache"
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case size = "Largest first", name = "Name", oldest = "Oldest first"
        var id: String { rawValue }
    }

    enum Mark { case none, some, all }

    var phase: Phase = .idle
    var snapshot: DockerSnapshot?
    var loading = false
    var measuring = false
    /// A removal or prune is running.
    var busy = false
    var section: Section = .images
    var sort: Sort = .size
    var query = ""
    var imageSel: Set<String> = []
    var containerSel: Set<String> = []
    var volumeSel: Set<String> = []
    private var sizes: DockerSizes?
    private var loadTask: Task<Void, Never>?
    private var measureTask: Task<Void, Never>?

    // MARK: - Loading

    func refresh() {
        guard !busy else { return }
        loadTask?.cancel()
        measureTask?.cancel()
        loading = true
        loadTask = Task {
            do {
                let s = try await DockerCleaner.load()
                guard !Task.isCancelled else { return }
                show(s)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                snapshot = nil
                clearSelection()
                phase = (error as? DockerUnavailable).map(Phase.unavailable) ?? .failed(AppError.from(error))
            }
            loading = false
        }
    }

    /// Show a fresh read (last known sizes carried over), then re-measure.
    private func show(_ s: DockerSnapshot) {
        snapshot = sizes.map { DockerCleaner.apply($0, to: s, usage: false) } ?? s
        phase = .ready
        loading = false
        pruneSelection()
        measure()
    }

    private func measure() {
        measureTask?.cancel()
        measuring = true
        measureTask = Task {
            let result = await DockerCleaner.measure()
            guard !Task.isCancelled else { return }
            if let result, let s = snapshot {
                sizes = result
                snapshot = DockerCleaner.apply(result, to: s)
                pruneSelection()
            }
            measuring = false
        }
    }

    // MARK: - Derived

    func matches(_ fields: String...) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || fields.contains { $0.lowercased().contains(q) }
    }

    var images: [DockerImage] {
        let list = (snapshot?.images ?? []).filter { matches($0.reference, $0.imageID) }
        switch sort {
        case .size: return list.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        case .name: return list.sorted { $0.reference.localizedStandardCompare($1.reference) == .orderedAscending }
        case .oldest: return list.sorted { ($0.created ?? .distantFuture) < ($1.created ?? .distantFuture) }
        }
    }

    var containers: [DockerContainer] {
        let list = (snapshot?.containers ?? []).filter { matches($0.name, $0.image, $0.id) }
        switch sort {
        case .size: return list.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        case .name: return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .oldest: return list.sorted { ($0.created ?? .distantFuture) < ($1.created ?? .distantFuture) }
        }
    }

    /// Volumes have no creation date in `volume ls`; oldest falls back to name.
    var volumes: [DockerVolume] {
        let list = (snapshot?.volumes ?? []).filter { matches($0.name, $0.composeProject ?? "") }
        switch sort {
        case .size: return list.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        case .name, .oldest: return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    var selectedImages: [DockerImage] { (snapshot?.images ?? []).filter { imageSel.contains($0.id) && $0.removable } }
    var selectedContainers: [DockerContainer] {
        (snapshot?.containers ?? []).filter { containerSel.contains($0.id) && $0.removable }
    }
    var selectedVolumes: [DockerVolume] { (snapshot?.volumes ?? []).filter { volumeSel.contains($0.name) && $0.removable } }

    /// Count and known bytes of the current section's selection.
    var selectionSummary: (count: Int, bytes: UInt64?) {
        switch section {
        case .images: (selectedImages.count, DockerActions.sum(selectedImages.map(\.freeableBytes)))
        case .containers: (selectedContainers.count, DockerActions.sum(selectedContainers.map(\.bytes)))
        case .volumes: (selectedVolumes.count, DockerActions.sum(selectedVolumes.map(\.bytes)))
        case .buildCache: (0, nil)
        }
    }

    func count(_ s: Section) -> Int {
        switch s {
        case .images: snapshot?.images.count ?? 0
        case .containers: snapshot?.containers.count ?? 0
        case .volumes: snapshot?.volumes.count ?? 0
        case .buildCache: snapshot?.usage(.buildCache)?.total ?? 0
        }
    }

    // MARK: - Selection

    func toggle(image i: DockerImage) { guard i.removable else { return }; imageSel.formSymmetricDifference([i.id]) }
    func toggle(container c: DockerContainer) {
        guard c.removable else { return }
        containerSel.formSymmetricDifference([c.id])
    }
    func toggle(volume v: DockerVolume) { guard v.removable else { return }; volumeSel.formSymmetricDifference([v.name]) }

    /// Header checkbox state for the visible, removable rows of the section.
    var mark: Mark {
        let (ids, sel) = visibleRemovable
        let n = ids.filter(sel.contains).count
        return n == 0 ? .none : n == ids.count ? .all : .some
    }

    func toggleAllVisible() {
        let ids = Set(visibleRemovable.ids)
        let all = mark == .all
        switch section {
        case .images: if all { imageSel.subtract(ids) } else { imageSel.formUnion(ids) }
        case .containers: if all { containerSel.subtract(ids) } else { containerSel.formUnion(ids) }
        case .volumes: if all { volumeSel.subtract(ids) } else { volumeSel.formUnion(ids) }
        case .buildCache: break
        }
    }

    private var visibleRemovable: (ids: [String], sel: Set<String>) {
        switch section {
        case .images: (images.filter(\.removable).map(\.id), imageSel)
        case .containers: (containers.filter(\.removable).map(\.id), containerSel)
        case .volumes: (volumes.filter(\.removable).map(\.name), volumeSel)
        case .buildCache: ([], [])
        }
    }

    func selectDanglingImages() { imageSel = Set(images.filter { $0.isDangling && $0.removable }.map(\.id)) }
    func selectAnonymousVolumes() { volumeSel = Set(volumes.filter { $0.removable && $0.isAnonymous }.map(\.name)) }

    func clearSelection() {
        imageSel = []
        containerSel = []
        volumeSel = []
    }

    /// Drop selections that vanished or became locked (an image now in use).
    private func pruneSelection() {
        guard let s = snapshot else { return clearSelection() }
        imageSel.formIntersection(s.images.filter(\.removable).map(\.id))
        containerSel.formIntersection(s.containers.filter(\.removable).map(\.id))
        volumeSel.formIntersection(s.volumes.filter(\.removable).map(\.name))
    }

    // MARK: - Actions

    func removeSelected(model: AppModel) {
        switch section {
        case .images: remove(images: selectedImages, model: model)
        case .containers: remove(containers: selectedContainers, model: model)
        case .volumes: remove(volumes: selectedVolumes, model: model)
        case .buildCache: prune(.buildCache, model: model)
        }
    }

    func remove(images: [DockerImage], model: AppModel) {
        let list = images.filter(\.removable)
        run("Removing \(DockerActions.plural(list.count, "image"))", noun: "image", model: model) {
            try await DockerActions.removeImages(list, confirmer: model.confirmer)
        }
    }

    func remove(containers: [DockerContainer], model: AppModel) {
        let list = containers.filter(\.removable)
        run("Removing \(DockerActions.plural(list.count, "container"))", noun: "container", model: model) {
            try await DockerActions.removeContainers(list, confirmer: model.confirmer)
        }
    }

    func remove(volumes: [DockerVolume], model: AppModel) {
        let list = volumes.filter(\.removable)
        run("Deleting \(DockerActions.plural(list.count, "volume"))", noun: "volume", model: model) {
            try await DockerActions.removeVolumes(list, confirmer: model.confirmer)
        }
    }

    func prune(_ p: DockerPrune, model: AppModel) {
        guard let current = snapshot else { return }
        let noun = switch p {
        case .danglingImages: "image"
        case .stoppedContainers: "container"
        case .buildCache: "cache entry"
        case .unusedVolumes: "volume"
        }
        run(p.title, noun: noun, model: model) {
            try await DockerActions.prune(p, current: current, confirmer: model.confirmer)
        }
    }

    private func run(_ label: String, noun: String, model: AppModel, _ op: @escaping () async throws -> DockerResult) {
        guard !busy, snapshot != nil else { return }
        // A read landing after the removal would show the old state.
        loadTask?.cancel()
        loading = false
        busy = true
        Task {
            do {
                let r = try await model.track(label) { try await op() }
                busy = false
                if let s = r.snapshot { show(s) } else { refresh() }
                model.toast(Self.message(r, noun: noun), isError: !r.failures.isEmpty && r.removed == 0)
            } catch {
                busy = false
                model.report(error)
                // A dismissed confirm changed nothing; anything else may have.
                if !AppError.from(error).isCancelled { refresh() }
            }
        }
    }

    /// "Freed 1.2 GB · removed 3 images" (+ what docker refused).
    static func message(_ r: DockerResult, noun: String) -> String {
        let plural = noun == "cache entry" ? (r.removed == 1 ? "cache entry" : "cache entries")
            : "\(noun)\(r.removed == 1 ? "" : "s")"
        let what = r.removed > 0 ? "removed \(r.removed) \(plural)" : "nothing was removed"
        var msg: String
        if let freed = r.freedBytes, freed > 0 {
            msg = "Freed \(Format.bytes(freed)) · \(what)"
        } else {
            msg = what.prefix(1).uppercased() + what.dropFirst()
        }
        if let first = r.failures.first {
            msg += " · \(r.failures.count) refused: \(first)"
        }
        return msg
    }
}
