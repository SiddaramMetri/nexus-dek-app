import Foundation
import NexusCore
import Observation

/// Tools tab data. Outlives the page view so returning to the tab is instant:
/// detection runs once per launch (plus explicit refreshes), latest versions
/// come from the on-disk cache and are re-checked at most once a day unless
/// the user asks.
@MainActor @Observable
final class ToolsStore {
    static let shared = ToolsStore()

    private(set) var tools: [DevTool]?
    private(set) var isDetecting = false
    private(set) var cache = ToolsUpdateCache.store.load() ?? ToolsUpdateCache()
    /// Tool ids with a latest-version lookup in flight.
    private(set) var checking: Set<String> = []
    private(set) var isChecking = false
    /// Update commands sent to the terminal — those rows offer "Re-check".
    private(set) var launched: Set<String> = []

    var query = ""
    var filter: ToolFilter = .all

    func status(_ tool: DevTool) -> ToolStatus {
        ToolStatus.resolve(installed: tool.version, record: cache.records[tool.latestKey])
    }

    func visible() -> [DevTool] {
        (tools ?? []).filter { filter.matches($0, status: status($0), query: query) }
    }

    var updatable: [DevTool] {
        (tools ?? []).filter { status($0).hasUpdate && ((try? ToolUpdate.command(for: $0)) ?? nil) != nil }
    }

    var updateCount: Int { (tools ?? []).filter { status($0).hasUpdate }.count }

    // MARK: - Loading

    /// Tab shown: detect once, then the daily automatic check if it's due.
    func appear(_ model: AppModel) async {
        if tools == nil { await detect(model) }
        if cache.isDue(), !isChecking { await checkAll(model) }
    }

    private func locator(_ model: AppModel) -> ToolLocator {
        ToolLocator(brewPrefix: model.context.brewPrefix)
    }

    func detect(_ model: AppModel) async {
        guard !isDetecting else { return }
        isDetecting = true
        defer { isDetecting = false }
        let prefix = model.context.brewPrefix
        tools = await Task.detached {
            await ToolDetector.detectAll(locator: ToolLocator(brewPrefix: prefix))
        }.value
    }

    /// "Check for updates": re-detect (versions may have changed), then look
    /// up every tool's latest version, 4 at a time; rows update as results land.
    func checkAll(_ model: AppModel, redetect: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        defer {
            isChecking = false
            checking = []
        }
        if redetect || tools == nil { await detect(model) }
        guard let tools else { return }
        await runChecks(tools, model: model)
        cache.checkedAt = Date()
        ToolsUpdateCache.store.save(cache)
    }

    /// After an update ran: re-read this tool's version and re-check it.
    func recheck(_ tool: DevTool, model: AppModel) async {
        guard !checking.contains(tool.id), let spec = ToolCatalog.spec(tool.id) else { return }
        checking.insert(tool.id)
        defer { checking.remove(tool.id) }
        let locator = locator(model)
        let fresh = await Task.detached { await ToolDetector.detect(spec, locator: locator) }.value
        if let i = tools?.firstIndex(where: { $0.id == tool.id }) {
            if let fresh { tools?[i] = fresh } else { tools?.remove(at: i) }
        }
        launched.remove(tool.id)
        if let fresh { await runChecks([fresh], model: model) }
        ToolsUpdateCache.store.save(cache)
    }

    private func runChecks(_ list: [DevTool], model: AppModel) async {
        checking.formUnion(list.map(\.id))
        let checker = ToolLatestChecker(locator: locator(model), brew: model.context.brewBin == nil ? nil : model.brew)
        await checker.check(list) { [weak self] tool, record in
            await self?.apply(tool, record)
        }
    }

    private func apply(_ tool: DevTool, _ record: LatestRecord) {
        cache.records[tool.latestKey] = record
        checking.remove(tool.id)
    }

    // MARK: - Updates

    private static var terminalDir: String { Paths.home.path + "/" }

    func update(_ tool: DevTool, model: AppModel) {
        Task {
            do {
                guard let cmd = try ToolUpdate.command(for: tool) else { return }
                let ok = await model.confirmer.confirm(
                    title: "Update \(tool.name)?",
                    message: "This runs in the terminal drawer, where you can watch it and answer any prompts:\n\n\(cmd)",
                    action: "Update", destructive: false)
                guard ok else { return }
                model.terminals.runInProject(dir: Self.terminalDir, title: "Update \(tool.name)", command: cmd)
                launched.insert(tool.id)
            } catch {
                model.report(error)
            }
        }
    }

    func updateAll(model: AppModel) {
        let list = updatable
        guard !list.isEmpty else { return }
        Task {
            do {
                guard let cmd = try ToolUpdate.batch(list) else { return }
                let names = list.map(\.name).joined(separator: ", ")
                let ok = await model.confirmer.confirm(
                    title: "Update \(list.count) \(list.count == 1 ? "tool" : "tools")?",
                    message: "\(names)\n\nThis runs in the terminal drawer, one after another:\n\n\(cmd)",
                    action: "Update all", destructive: false)
                guard ok else { return }
                model.terminals.runInProject(dir: Self.terminalDir, title: "Update tools", command: cmd)
                launched.formUnion(list.map(\.id))
            } catch {
                model.report(error)
            }
        }
    }
}
