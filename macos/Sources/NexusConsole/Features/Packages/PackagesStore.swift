import AppKit
import NexusCore
import Observation

/// Packages tab data. Outlives the page view (the tab is rebuilt on every
/// switch) so returning to the tab shows the last list instantly and only
/// refetches once stale — the React Query cache it replaces.
@MainActor @Observable
final class PackagesStore {
    static let shared = PackagesStore()

    static let listStaleAfter: TimeInterval = 60
    static let infoStaleAfter: TimeInterval = 5 * 60

    private(set) var installed: [PackageItem]?
    private(set) var listError: AppError?
    private(set) var isFetching = false
    private var listFetchedAt: Date?

    /// nil until the slow `brew outdated` lands; badges merge in when it does.
    private(set) var outdated: [OutdatedInfo]?
    private(set) var isCheckingOutdated = false
    private var outdatedFetchedAt: Date?

    private var infoCache: [String: (details: PackageDetails, at: Date)] = [:]

    private(set) var upgrading: Set<String> = []
    private(set) var isUpgradingAll = false
    private(set) var uninstalling: Set<String> = []

    /// Installed list with outdated status merged on.
    var packages: [PackageItem] { PackagesBackend.merge(installed ?? [], outdated: outdated) }

    var isPending: Bool { installed == nil && listError == nil }

    // MARK: - Loading

    private static func isStale(_ at: Date?, _ ttl: TimeInterval) -> Bool {
        guard let at else { return true }
        return Date().timeIntervalSince(at) >= ttl
    }

    /// Tab shown / app refocused: refetch whatever is older than its TTL.
    func refreshIfStale(_ backend: PackagesBackend) {
        if Self.isStale(listFetchedAt, Self.listStaleAfter) { Task { await reloadList(backend) } }
        if Self.isStale(outdatedFetchedAt, Self.listStaleAfter) { Task { await reloadOutdated(backend) } }
    }

    /// After a mutation: both the list and the outdated status changed.
    func invalidate(_ backend: PackagesBackend) {
        Task { await reloadList(backend) }
        Task { await reloadOutdated(backend) }
    }

    func reloadList(_ backend: PackagesBackend) async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        do {
            installed = try await backend.list()
            listError = nil
            listFetchedAt = Date()
        } catch {
            listError = AppError.from(error)
        }
    }

    func reloadOutdated(_ backend: PackagesBackend) async {
        guard !isCheckingOutdated else { return }
        isCheckingOutdated = true
        defer { isCheckingOutdated = false }
        do {
            outdated = try await backend.outdated()
            outdatedFetchedAt = Date()
        } catch {
            // `outdated()` swallows brew failures; only "Homebrew not found" lands here.
            outdated = []
        }
    }

    func info(_ name: String, _ backend: PackagesBackend) async throws -> PackageDetails {
        if let hit = infoCache[name], !Self.isStale(hit.at, Self.infoStaleAfter) { return hit.details }
        let details = try await backend.info(name)
        infoCache[name] = (details, Date())
        return details
    }

    // MARK: - Mutations

    func upgrade(_ name: String, model: AppModel) {
        let backend = PackagesBackend(brew: model.brew)
        upgrading.insert(name)
        Task {
            do {
                try await model.track("Upgrading \(name)") { try await backend.upgrade(name) }
                model.toast("Upgraded \(name)")
            } catch {
                model.report(error)
            }
            upgrading.remove(name)
            invalidate(backend)
        }
    }

    /// `brew upgrade` touches every outdated package — confirm first.
    func upgradeAll(count: Int, model: AppModel) {
        let backend = PackagesBackend(brew: model.brew)
        Task {
            let ok = await model.confirmer.confirm(
                title: "Upgrade \(count) package\(count == 1 ? "" : "s")?",
                message: "Runs brew upgrade. Pinned packages are skipped. This can take several minutes.",
                action: "Upgrade all", destructive: false)
            guard ok else { return }
            isUpgradingAll = true
            do {
                try await model.track("Upgrading \(count) packages") { try await backend.upgradeAll() }
                model.toast("Upgraded all packages")
            } catch {
                model.report(error)
            }
            isUpgradingAll = false
            invalidate(backend)
        }
    }

    /// The uninstall dialog is the confirmation; dependents were shown there.
    func uninstall(_ name: String, ignoreDependents: Bool, model: AppModel) async -> Bool {
        let backend = PackagesBackend(brew: model.brew)
        uninstalling.insert(name)
        defer { uninstalling.remove(name) }
        var ok = false
        do {
            try await model.track("Uninstalling \(name)") {
                try await model.services.uninstall(name, ignoreDependents: ignoreDependents)
            }
            model.removeManaged(name)
            model.toast("Uninstalled \(name)")
            ok = true
        } catch {
            model.report(error)
        }
        invalidate(backend)
        await model.refreshServices()
        return ok
    }

    /// Native confirm + `brew trust --tap`, then reload everything it was blocking.
    func trustTap(_ tap: String, model: AppModel) {
        let backend = PackagesBackend(brew: model.brew)
        model.perform("Trusted \(tap)") {
            try await model.services.trustTap(tap, confirmer: model.confirmer)
            self.invalidate(backend)
            await model.refreshServices()
        }
    }
}
