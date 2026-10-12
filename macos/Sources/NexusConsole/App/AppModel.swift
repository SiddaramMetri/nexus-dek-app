import Foundation
import NexusCore
import Observation
import UserNotifications

enum Tab: String, CaseIterable, Identifiable {
    case services, packages, sessions, ports, doctor, archiver, settings
    var id: String { rawValue }

    var label: String {
        switch self {
        case .services: "Services"
        case .packages: "Packages"
        case .sessions: "Sessions"
        case .ports: "Ports"
        case .doctor: "Doctor"
        case .archiver: "Claude Chats"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .services: "square.grid.2x2"
        case .packages: "shippingbox"
        case .sessions: "clock"
        case .ports: "network"
        case .doctor: "stethoscope"
        case .archiver: "archivebox"
        case .settings: "gearshape"
        }
    }

    /// The module that owns this tab; nil = always visible (Settings).
    var module: ModuleID? {
        switch self {
        case .services, .packages, .sessions: .homebrew
        case .ports: .ports
        case .doctor: .doctor
        case .archiver: .claude
        case .settings: nil
        }
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let isError: Bool
}

/// App-wide state: persisted settings + user intent, the live services poll,
/// toasts. Feature pages own their own view state.
@MainActor @Observable
final class AppModel {
    let context = AppContext.discover()
    let brew: Brew
    let services: ServicesBackend
    let confirmer = AlertConfirmer()
    let terminals: TerminalManager
    var brewVersion: String?

    var tab: Tab = .services
    var toasts: [Toast] = []
    /// In-flight brew work, shown by the activity bar ("Installing redis…").
    var activities: [(id: UUID, label: String)] = []
    /// Bumped by ⌘F; the visible page's search field focuses itself.
    var searchFocusToken = 0

    var settings: AppSettings { didSet { if settings != oldValue { Stores.settings.save(settings) } } }
    var intent: ServiceIntent { didSet { if intent != oldValue { Stores.serviceIntent.save(intent) } } }
    var runs: [String: [Run]] = [:]

    // Live services
    var brewServices: [ServiceInfo] = []
    var servicesLoaded = false
    var servicesError: AppError?
    /// Optimistic status while a start/stop is in flight.
    var pending: [String: DisplayStatus] = [:]
    /// Formulas the user stopped on purpose — a stop without one is a crash.
    private var userStops: Set<String> = []
    private var lastStatus: [String: DisplayStatus] = [:]
    private var pollTask: Task<Void, Never>?
    private var traySignature = ""

    var onTrayChange: (() -> Void)?

    init() {
        brew = Brew(context: context)
        services = ServicesBackend(brew: brew)
        settings = Stores.settings.load() ?? AppSettings()
        intent = Stores.serviceIntent.load() ?? ServiceIntent()
        runs = Stores.sessions.load() ?? [:]
        terminals = TerminalManager(brewPrefix: context.brewPrefix ?? "/opt/homebrew")
        if let first = visibleTabs.first { tab = first }
        // `open "Nexus Console.app" --args -NexusTab doctor` starts on a given tab.
        if let raw = UserDefaults.standard.string(forKey: "NexusTab"), let t = Tab(rawValue: raw),
           visibleTabs.contains(t) { tab = t }
    }

    func start() {
        Task { brewVersion = await brew.version() }
        Scheduler.start(model: self)
        restartPolling()
    }

    // MARK: - Navigation

    var visibleTabs: [Tab] {
        Tab.allCases.filter { t in t.module.map { settings.isEnabled($0) && $0.isAvailable } ?? true }
    }

    var needsOnboarding: Bool { settings.enabledModules == nil }

    // MARK: - Toasts

    func report(_ error: Error) {
        let e = AppError.from(error)
        if e.isCancelled { return }
        toast(e.message, isError: e.kind != "busy")
    }

    func toast(_ message: String, isError: Bool = false) {
        let t = Toast(message: message, isError: isError)
        toasts.append(t)
        Task {
            try? await Task.sleep(for: .seconds(isError ? 6 : 3.5))
            toasts.removeAll { $0.id == t.id }
        }
    }

    /// Brew is slow and silent — label the work so the activity bar can show it.
    @discardableResult
    func track<T>(_ label: String, _ body: () async throws -> T) async rethrows -> T {
        let id = UUID()
        activities.append((id, label))
        defer { activities.removeAll { $0.id == id } }
        return try await body()
    }

    /// Run an async action, toasting any failure.
    func perform(_ success: String? = nil, _ body: @escaping () async throws -> Void) {
        Task {
            do {
                try await body()
                if let success { toast(success) }
            } catch {
                report(error)
            }
        }
    }

    // MARK: - Services poll

    func restartPolling() {
        pollTask?.cancel()
        guard settings.isEnabled(.homebrew), context.brewBin != nil else {
            brewServices = []
            refreshTray()
            return
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshServices()
                let ms = self?.settings.pollIntervalMs ?? 4000
                try? await Task.sleep(for: .milliseconds(ms))
            }
        }
    }

    func refreshServices() async {
        do {
            let list = try await services.list(withStats: tab == .services)
            brewServices = list
            servicesError = nil
            servicesLoaded = true
            seedIfNeeded()
        } catch {
            let e = AppError.from(error)
            if e.kind != "busy" { servicesError = e }
        }
        recordSessions()
        refreshTray()
    }

    var reconciled: [ReconciledService] {
        var list = Reconcile.merge(managed: intent.managed, brew: brewServices, intent: intent.intent)
        for i in list.indices { if let p = pending[list[i].formula] { list[i].status = p } }
        let order = settings.cardOrder
        guard !order.isEmpty else { return list }
        return list.sorted { (order.firstIndex(of: $0.formula) ?? .max) < (order.firstIndex(of: $1.formula) ?? .max) }
    }

    /// First run: seed the managed list from the brew services on this Mac.
    private func seedIfNeeded() {
        guard !intent.seeded, !brewServices.isEmpty else { return }
        intent.managed = brewServices.map { ManagedService(formula: $0.name, displayName: Format.formulaDisplayName($0.name)) }
        intent.seeded = true
    }

    // MARK: - Service actions

    func startService(_ s: ReconciledService) {
        pending[s.formula] = .starting
        perform {
            defer { self.pending[s.formula] = nil }
            try await self.track("Starting \(s.displayName)") {
                try await self.services.start(s.formula, linked: s.linkState == .linked)
            }
            await self.refreshServices()
        }
    }

    func stopService(_ s: ReconciledService) {
        userStops.insert(s.formula)
        pending[s.formula] = .stopping
        perform {
            defer { self.pending[s.formula] = nil }
            do { try await self.track("Stopping \(s.displayName)") { try await self.services.stop(s.formula) } } catch {
                self.userStops.remove(s.formula)
                throw error
            }
            await self.refreshServices()
        }
    }

    func restartService(_ s: ReconciledService) {
        pending[s.formula] = .starting
        perform {
            defer { self.pending[s.formula] = nil }
            try await self.track("Restarting \(s.displayName)") {
                try await self.services.restart(s.formula, linked: s.linkState == .linked)
            }
            await self.refreshServices()
        }
    }

    /// Flip start-at-login. A running service is migrated between start/run.
    func setLink(_ s: ReconciledService, _ link: LinkState) {
        intent.intent[s.formula] = link
        guard s.status == .running || s.status == .starting else { return }
        pending[s.formula] = .starting
        perform {
            defer { self.pending[s.formula] = nil }
            try await self.track(link == .linked ? "Linking \(s.displayName)" : "Unlinking \(s.displayName)") {
                try await self.services.restart(s.formula, linked: link == .linked)
            }
            await self.refreshServices()
        }
    }

    /// Stop all running — confirmed natively, naming the count + services.
    func bulkStop(_ list: [ReconciledService]) {
        let running = list.filter(\.isRunning)
        guard !running.isEmpty else { return }
        Task {
            let names = running.map(\.displayName)
            let shown = names.count <= 8 ? names.joined(separator: ", ")
                : names.prefix(8).joined(separator: ", ") + " +\(names.count - 8) more"
            let ok = await confirmer.confirm(
                title: "Stop all services",
                message: "Stop all \(running.count) running service\(running.count == 1 ? "" : "s")?\n\(shown)",
                action: "Stop all", destructive: true)
            guard ok else { return }
            await runBulk("Stopped", running) { s in
                self.userStops.insert(s.formula)
                self.pending[s.formula] = .stopping
                defer { self.pending[s.formula] = nil }
                do { try await self.services.stop(s.formula) } catch { self.userStops.remove(s.formula); throw error }
            }
        }
    }

    /// Start is safe and reversible — no confirm.
    func bulkStart(_ list: [ReconciledService]) {
        let stopped = list.filter { $0.status == .stopped || $0.status == .error }
        Task {
            await runBulk("Started", stopped) { s in
                self.pending[s.formula] = .starting
                defer { self.pending[s.formula] = nil }
                try await self.services.start(s.formula, linked: s.linkState == .linked)
            }
        }
    }

    private func runBulk(_ verb: String, _ list: [ReconciledService],
                         _ op: (ReconciledService) async throws -> Void) async {
        var failed = 0
        await track("\(verb == "Stopped" ? "Stopping" : "Starting") \(list.count) service\(list.count == 1 ? "" : "s")") {
            for s in list {
                do { try await op(s) } catch { failed += 1 }
            }
        }
        await refreshServices()
        let n = list.count
        let noun = n == 1 ? "service" : "services"
        if failed > 0 {
            toast("\(verb) \(n - failed) of \(n) \(noun) — \(failed) failed", isError: true)
        } else {
            toast("\(verb) \(n) \(noun)")
        }
    }

    func addManaged(_ formula: String) {
        let bare = bareFormula(formula)
        guard !intent.managed.contains(where: { bareFormula($0.formula) == bare }) else { return }
        intent.managed.append(ManagedService(formula: formula, displayName: Format.formulaDisplayName(formula)))
    }

    func removeManaged(_ formula: String) {
        intent.managed.removeAll { $0.formula == formula }
        intent.intent[formula] = nil
    }

    /// Point a card at the formula actually installed (renamed tap build / version switch).
    func renameManaged(from: String, to: String) {
        guard from != to, let i = intent.managed.firstIndex(where: { $0.formula == from }) else { return }
        intent.managed[i].formula = to
        if let link = intent.intent.removeValue(forKey: from) { intent.intent[to] = link }
    }

    func install(_ s: ReconciledService) {
        pending[s.formula] = .starting
        perform("Installed \(s.displayName)") {
            defer { self.pending[s.formula] = nil }
            let installed = try await self.track("Installing \(s.formula)") { try await self.services.install(s.formula) }
            self.renameManaged(from: s.formula, to: installed)
            await self.refreshServices()
        }
    }

    /// Install a different version and point the card at it.
    func switchVersion(_ s: ReconciledService, to version: String) {
        pending[s.formula] = .starting
        perform("Switched to \(version)") {
            defer { self.pending[s.formula] = nil }
            if s.status == .running || s.status == .starting { try? await self.services.stop(s.formula) }
            let installed = try await self.track("Installing \(version)") { try await self.services.install(version) }
            self.renameManaged(from: s.formula, to: installed)
            await self.refreshServices()
        }
    }

    func trustTap(_ tap: String) {
        perform("Trusted \(tap)") {
            try await self.track("Trusting \(tap)") { try await self.services.trustTap(tap, confirmer: self.confirmer) }
            await self.refreshServices()
        }
    }

    // MARK: - Sessions

    /// Records run history by diffing successive polls; a stop the user didn't
    /// ask for fires a crash notification.
    private func recordSessions() {
        let now = Date().timeIntervalSince1970 * 1000
        var seen = Set<String>()
        var changed = false
        for s in reconciled {
            seen.insert(s.formula)
            let was = lastStatus[s.formula]
            let wasRunning = was == .running || was == .starting
            let isRunning = s.status == .running || s.status == .starting
            let isStopped = s.status == .stopped || s.status == .error
            if !wasRunning && isRunning {
                openRun(s.formula, startMs: now - Double(s.uptimeSecs ?? 0) * 1000)
                changed = true
                lastStatus[s.formula] = s.status
            } else if wasRunning && isStopped {
                closeRun(s.formula, endMs: now)
                changed = true
                if userStops.remove(s.formula) == nil { notifyCrash(s.displayName) }
                lastStatus[s.formula] = s.status
            } else if isRunning || isStopped {
                lastStatus[s.formula] = s.status
            }
        }
        for formula in lastStatus.keys where !seen.contains(formula) {
            closeRun(formula, endMs: now)
            lastStatus[formula] = nil
            changed = true
        }
        if changed { persistRuns() }
    }

    private func openRun(_ formula: String, startMs: Double) {
        var arr = runs[formula] ?? []
        if let last = arr.last, last.endMs == nil { return }
        arr.append(Run(startMs: max(startMs, arr.last?.endMs ?? 0), endMs: nil))
        if arr.count > 50 { arr.removeFirst(arr.count - 50) }
        runs[formula] = arr
    }

    private func closeRun(_ formula: String, endMs: Double) {
        guard var arr = runs[formula], let last = arr.last, last.endMs == nil else { return }
        arr[arr.count - 1].endMs = endMs
        runs[formula] = arr
    }

    func clearSessions() {
        runs = runs.mapValues { $0.filter { $0.endMs == nil } }.filter { !$0.value.isEmpty }
        persistRuns()
    }

    /// Only closed runs persist — open runs are re-derived from process uptime on launch.
    private func persistRuns() {
        Stores.sessions.save(runs.mapValues { $0.filter { $0.endMs != nil } }.filter { !$0.value.isEmpty })
    }

    private func notifyCrash(_ name: String) {
        Notifier.post(title: "Service stopped", body: "\(name) stopped unexpectedly.")
    }

    // MARK: - Tray

    var trayTitle: String = ""
    var trayServices: [(name: String, running: Bool)] = []

    private func refreshTray() {
        let list = settings.isEnabled(.homebrew) ? reconciled : []
        let isRunning = { (s: ReconciledService) in s.status == .running || s.status == .starting }
        let sig = list.map { "\($0.displayName):\($0.status != .notInstalled):\(isRunning($0))" }.joined(separator: "|")
            + "#\(settings.isEnabled(.homebrew))"
        guard sig != traySignature else { return }
        traySignature = sig
        trayTitle = list.isEmpty ? "" : "\(list.filter(isRunning).count)/\(list.count)"
        trayServices = list.filter { $0.status != .notInstalled }.map { ($0.displayName, isRunning($0)) }
        onTrayChange?()
    }

    /// Flip to an explicit light/dark theme (from the header, sidebar or ⇧⌘L).
    func toggleTheme(currentlyDark: Bool) {
        settings.theme = currentlyDark ? .light : .dark
    }

    func settingsChanged() {
        traySignature = ""
        restartPolling()
    }
}

/// Local notifications. Requires a bundled app (no-op when run unbundled).
enum Notifier {
    static func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
