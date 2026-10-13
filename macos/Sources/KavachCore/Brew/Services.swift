import Foundation

/// One brew service, flat and Optional-typed.
public struct ServiceInfo: Equatable, Sendable {
    public var name: String
    public var status: String
    public var pid: Int32?
    public var cpu: Double?
    public var memoryBytes: UInt64?
    public var uptimeSecs: UInt64?
    public var port: Int?
    public var healthy: Bool?
    public var plist: String?
}

struct BrewServiceEntry: Codable, Equatable, Sendable {
    var name: String
    var status: String
    var file: String?
}

/// Brew services backend: listing (cached), start/stop/restart, install, search.
public final class ServicesBackend: Sendable {
    public let brew: Brew
    let cache = ServicesCache()
    /// Services THIS app started ephemerally (`brew services run`) this session —
    /// the only ones stopped on quit. Runtime-only, never persisted.
    let ephemeral = Locked<Set<String>>([])

    public init(brew: Brew) { self.brew = brew }

    // MARK: - Read

    /// Status + pid always; cpu/mem/port/health only `withStats` (the sidebar
    /// badge and tray stay cheap).
    public func list(withStats: Bool) async throws -> [ServiceInfo] {
        let pids = Parsers.launchctl(await Proc.anyOutput("launchctl", ["list"]))
        let entries = try await fetchList(pids: pids)

        var samples: [Int32: Parsers.PsSample] = [:]
        var ports: [Int32: Int] = [:]
        if withStats, !pids.isEmpty {
            let ids = pids.values.map(String.init).joined(separator: ",")
            async let ps = Proc.anyOutput("ps", ["-o", "pid=,%cpu=,rss=,etime=", "-p", ids])
            async let lsof = Proc.anyOutput("lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", ids])
            samples = Parsers.ps(await ps)
            ports = Parsers.listeningPorts(await lsof)
        }

        return entries.map { e in
            let pid = pids[e.name]
            let s = pid.flatMap { samples[$0] }
            let port = pid.flatMap { ports[$0] }
            return ServiceInfo(
                name: e.name, status: e.status, pid: pid,
                cpu: s?.cpu, memoryBytes: s?.rssBytes, uptimeSecs: s?.uptimeSecs,
                port: port,
                // Real listening port from lsof; its presence is the health signal.
                healthy: withStats && e.status == "started" ? port != nil : nil,
                plist: e.file
            )
        }
    }

    /// Cached `brew services list --json` (~1.6s wall). Reused while the pid map
    /// is unchanged and the TTL holds. If a brew mutation is in flight, serve the
    /// last known list instead of racing brew's file lock.
    func fetchList(pids: [String: Int32]) async throws -> [BrewServiceEntry] {
        if let fresh = await cache.fresh(pids: pids) { return fresh }
        guard await brew.lock.tryLock() else {
            if let stale = await cache.lastKnown { return stale }
            throw AppError.busy(Brew.busyMessage)
        }
        let out: ProcOutput
        do {
            out = try await brew.raw(["services", "list", "--json"])
            await brew.lock.unlock()
        } catch {
            await brew.lock.unlock()
            throw error
        }
        guard out.ok else {
            let err = Brew.classify(stderr: out.err)
            if case .busy = err, let stale = await cache.lastKnown { return stale }
            throw err
        }
        let entries: [BrewServiceEntry]
        do { entries = try JSONDecoder().decode([BrewServiceEntry].self, from: out.stdout) } catch {
            throw AppError.parse("brew services json: \(error.localizedDescription)")
        }
        await cache.store(entries, pids: pids)
        return entries
    }

    // MARK: - Write

    /// linked → `brew services start` (launchd-registered, persists);
    /// unlinked → `brew services run` (ephemeral, stopped on quit).
    public func start(_ name: String, linked: Bool) async throws {
        try Validate.formula(name)
        let action = linked ? "start" : "run"
        try await brew.lock.withLock {
            // A wedged launchd label makes `start` fail with "Bootstrap failed: 5"
            // while brew still reports it stopped. Bootout + retry once.
            if (try? await self.brew.run(["services", action, name])) == nil {
                _ = try? await self.brew.run(["services", "stop", name])
                try await self.brew.run(["services", action, name])
            }
        }
        recordIntent(name, linked: linked)
        await cache.invalidate()
    }

    public func stop(_ name: String) async throws {
        try Validate.formula(name)
        try await brew.mutate(["services", "stop", name])
        _ = ephemeral.with { $0.remove(name) }
        await cache.invalidate()
    }

    /// Restart, or migrate a running service between start (registered) and run (ephemeral).
    public func restart(_ name: String, linked: Bool) async throws {
        try Validate.formula(name)
        try await brew.lock.withLock {
            try await self.brew.run(["services", "stop", name])
            try await self.brew.run(["services", linked ? "start" : "run", name])
        }
        recordIntent(name, linked: linked)
        await cache.invalidate()
    }

    /// Returns the formula actually installed (not always the name asked for).
    public func install(_ name: String) async throws -> String {
        try Validate.formula(name)
        let target = try await brew.lock.withLock { () -> String in
            let target = try await self.resolveInstallable(name)
            try await self.brew.run(["install", target])
            return target
        }
        await cache.invalidate()
        return target
    }

    public func uninstall(_ name: String, ignoreDependents: Bool) async throws {
        try Validate.formula(name)
        var args = ["uninstall"]
        if ignoreDependents { args.append("--ignore-dependencies") }
        args.append(name)
        try await brew.mutate(args)
        await cache.invalidate()
    }

    /// Native confirm, then `brew trust --tap <tap>` (user-level, no sudo).
    public func trustTap(_ tap: String, confirmer: Confirmer) async throws {
        try Validate.tap(tap)
        try await confirmer.require(
            title: "Trust this Homebrew tap?",
            message: """
            Homebrew won't load anything from “\(tap)” until you trust it once, so installs, versions and package lists fail while it's untrusted.

            Kavach will run:  brew trust --tap \(tap)

            Only trust taps you added yourself. No administrator password is needed.
            """,
            action: "Trust tap", destructive: false)
        try await brew.mutate(["trust", "--tap", tap])
        await cache.invalidate()
    }

    public func invalidateCache() async { await cache.invalidate() }

    // MARK: - Search

    public func search(_ query: String) async throws -> [String] {
        guard !query.isEmpty, query.count <= 64 else { throw AppError.invalidName("invalid search query") }
        return try await brew.run(["search", query])
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("==>") }
    }

    /// The base + its `@version` variants (redis → [redis, redis@6.2, redis@8.2]).
    public func versions(_ name: String) async throws -> [String] {
        try Validate.formula(name)
        let base = Self.baseName(name)
        return Self.pickVersions(try await brew.run(["search", base]), base: base)
    }

    static func baseName(_ name: String) -> String {
        bareFormula(String(name.split(separator: "@", omittingEmptySubsequences: false).first ?? ""))
    }

    func resolveInstallable(_ name: String) async throws -> String {
        let base = Self.baseName(name)
        let candidates = Self.pickVersions(try await brew.run(["search", base]), base: base)
        if candidates.contains(name) { return name }
        return candidates.first ?? name
    }

    /// `brew search <base>` → base first, then `@version` variants. Falls back
    /// to a prefix match when core dropped the formula and only a renamed tap
    /// build remains (elasticsearch → elastic/tap/elasticsearch-full).
    static func pickVersions(_ out: String, base: String) -> [String] {
        let lines = out.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("==>") }
        var picked = lines.filter { let b = bareFormula($0); return b == base || b.hasPrefix(base + "@") }
        if picked.isEmpty { picked = lines.filter { bareFormula($0).hasPrefix(base) } }
        var seen = Set<String>()
        return picked
            .sorted { (bareFormula($0) != base ? 1 : 0, $0) < (bareFormula($1) != base ? 1 : 0, $1) }
            .filter { seen.insert($0).inserted }
    }

    // MARK: - Session (quit) tracking

    func recordIntent(_ name: String, linked: Bool) {
        ephemeral.with { set in
            if linked { set.remove(name) } else { set.insert(name) }
        }
    }

    /// On quit: stop services this app started ephemerally this session, with a
    /// hard deadline so a hung `brew` can never freeze the quit.
    public func stopEphemeral(deadline: TimeInterval = 5) {
        let names = ephemeral.snapshot
        guard !names.isEmpty, let bin = brew.context.brewBin else { return }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for name in names {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = ["services", "stop", name]
                p.environment = ProcessInfo.processInfo.environment.merging(Brew.env) { _, n in n }
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                p.waitUntilExit()
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + deadline)
    }
}

/// Caches `brew services list --json` — re-running it every poll was the single
/// biggest CPU cost. Every write invalidates it.
actor ServicesCache {
    static let ttl: TimeInterval = 60
    private var entries: [BrewServiceEntry]?
    private var pidMap: [String: Int32] = [:]
    private var fetchedAt = Date.distantPast

    func fresh(pids: [String: Int32], now: Date = Date()) -> [BrewServiceEntry]? {
        guard let entries, pidMap == pids, now.timeIntervalSince(fetchedAt) < Self.ttl else { return nil }
        return entries
    }

    var lastKnown: [BrewServiceEntry]? { entries }

    func store(_ e: [BrewServiceEntry], pids: [String: Int32], at: Date = Date()) {
        entries = e
        pidMap = pids
        fetchedAt = at
    }

    func invalidate() { entries = nil }
}
