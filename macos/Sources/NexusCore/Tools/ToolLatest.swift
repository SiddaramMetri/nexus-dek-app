import Foundation

/// Where a tool's latest version comes from. Every lookup is read-only.
public enum LatestSource: Equatable, Sendable {
    /// One `brew outdated --json=v2` for all brew tools.
    case brew
    /// `npm view <pkg> version`.
    case npm(String)
    /// Newest Node.js release in the installed major line (nodejs.org index).
    case nodeDist(major: Int)
    case pypi(String)
    /// GitHub's latest release tag (`owner/repo`).
    case github(String)
    /// `rustup check`.
    case rustup
    /// Nothing to compare — this note is the status ("Updates itself").
    case note(String)
    case none

    public static func of(_ tool: DevTool) -> LatestSource {
        switch tool.method {
        case .brewFormula, .brewCask: return .brew
        case .homebrewSelf: return .github("Homebrew/brew")
        case let .npmGlobal(pkg, _): return .npm(pkg)
        case .claudeNative: return .npm("@anthropic-ai/claude-code")
        case .codexStandalone: return .npm("@openai/codex")
        case .nvm, .installerPackage where tool.id == "node":
            return tool.version.flatMap(ToolVersion.major).map { .nodeDist(major: $0) } ?? .none
        case .rustup where tool.id == "rust": return .rustup
        case .uvStandalone: return .pypi("uv")
        case .bunInstaller: return .npm("bun")
        case .denoInstaller: return .github("denoland/deno")
        case .app: return .note("Updates itself")
        case let .bundled(app): return .note("Updated with \(app)")
        case .commandLineTools: return .note("Via Software Update")
        default: return .none
        }
    }
}

/// Runs latest-version lookups: brew once for all brew tools, the rest a few
/// at a time. Results stream back per tool so rows fill in as they land.
public struct ToolLatestChecker: Sendable {
    public let locator: ToolLocator
    public let brew: Brew?
    public static let concurrency = 4

    public init(locator: ToolLocator, brew: Brew?) {
        self.locator = locator
        self.brew = brew
    }

    public func check(_ tools: [DevTool], onResult: @escaping @Sendable (DevTool, LatestRecord) async -> Void) async {
        let brewTools = tools.filter { LatestSource.of($0) == .brew }
        let others = tools.filter { LatestSource.of($0) != .brew }
        async let brewDone: Void = checkBrew(brewTools, onResult: onResult)
        await withTaskGroup(of: Void.self) { group in
            var queue = others[...]
            func next() {
                guard let tool = queue.popFirst() else { return }
                group.addTask { await onResult(tool, await self.lookup(tool)) }
            }
            for _ in 0 ..< Self.concurrency { next() }
            while await group.next() != nil { next() }
        }
        await brewDone
    }

    func checkBrew(_ tools: [DevTool], onResult: @escaping @Sendable (DevTool, LatestRecord) async -> Void) async {
        guard !tools.isEmpty else { return }
        var outdated: [String: String?]?
        if let brew {
            let out = await ToolDetector.withTimeout(.seconds(120)) { try? await brew.raw(["outdated", "--json=v2"]) }
            outdated = out.flatMap { Self.parseBrewOutdated($0.out) }
        }
        for tool in tools {
            guard let outdated, let name = Self.brewName(tool.method) else {
                await onResult(tool, .failed())
                continue
            }
            if let latest = outdated[name] {
                await onResult(tool, LatestRecord(latest: latest, outdated: true))
            } else {
                await onResult(tool, LatestRecord(outdated: false))
            }
        }
    }

    static func brewName(_ method: InstallMethod) -> String? {
        switch method {
        case let .brewFormula(n), let .brewCask(n): n
        default: nil
        }
    }

    public func lookup(_ tool: DevTool) async -> LatestRecord {
        let latest: String?
        switch LatestSource.of(tool) {
        case let .note(note): return LatestRecord(note: note)
        case .none, .brew: return .failed()
        case let .npm(pkg): latest = await npmView(pkg, for: tool)
        case let .nodeDist(major):
            latest = await fetch("https://nodejs.org/dist/index.json").flatMap { Self.parseNodeDist($0, major: major) }
        case let .pypi(pkg): latest = await fetch("https://pypi.org/pypi/\(pkg)/json").flatMap(Self.parsePyPI)
        case let .github(repo):
            latest = await fetch("https://api.github.com/repos/\(repo)/releases/latest").flatMap(Self.parseGitHubRelease)
        case .rustup:
            let rustup = (tool.path as NSString).deletingLastPathComponent + "/rustup"
            latest = await ToolDetector.capture(rustup, ["check"], env: ToolDetector.env(locator), timeout: .seconds(30))
                .flatMap(Self.parseRustupCheck)
        }
        return latest.map { LatestRecord(latest: $0) } ?? .failed()
    }

    // MARK: - npm

    /// The npm next to the package's own node (`<prefix>/bin/npm`), else the active one.
    func npm(for tool: DevTool) -> String? {
        if case .npmGlobal = tool.method, let r = tool.resolvedPath.range(of: "/lib/node_modules/", options: .backwards) {
            let candidate = tool.resolvedPath[..<r.lowerBound] + "/bin/npm"
            if FileManager.default.isExecutableFile(atPath: String(candidate)) { return String(candidate) }
        }
        return locator.find("npm")
    }

    func npmView(_ pkg: String, for tool: DevTool) async -> String? {
        guard NpmName.isValid(pkg) else { return nil }
        if let npm = npm(for: tool) {
            var env = ToolDetector.env(locator)
            env["PATH"] = (npm as NSString).deletingLastPathComponent + ":" + locator.pathEnv
            let out = await ToolDetector.capture(npm, ["view", pkg, "version"], env: env, timeout: .seconds(30))
            if let v = out.flatMap(Self.parseNpmView) { return v }
        }
        // No npm here (or it failed): ask the registry directly.
        return await fetch("https://registry.npmjs.org/\(pkg)/latest").flatMap(Self.parseNpmLatest)
    }

    func fetch(_ url: String) async -> Data? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("dev-tools-update-check", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // MARK: - Parsing (pure)

    /// `brew outdated --json=v2` → name → latest (nil latest = outdated, unknown target).
    /// nil for anything that isn't the expected JSON, so a failure never reads as "up to date".
    static func parseBrewOutdated(_ json: String) -> [String: String?]? {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              root["formulae"] != nil || root["casks"] != nil else { return nil }
        var out: [String: String?] = [:]
        for key in ["formulae", "casks"] {
            for e in root[key] as? [[String: Any]] ?? [] {
                guard let name = e["name"] as? String else { continue }
                let latest = e["current_version"] as? String
                out[name] = latest
                out[bareFormula(name)] = latest
            }
        }
        return out
    }

    /// `2.1.300\n` → `2.1.300` (also tolerates `--json` quoting).
    static func parseNpmView(_ out: String) -> String? {
        let line = out.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let v = line.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t"))
        return ToolVersion.normalize(v) != nil ? v : nil
    }

    static func parseNpmLatest(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["version"] as? String
    }

    /// Newest `vMAJOR.x.y` in nodejs.org's dist index.
    static func parseNodeDist(_ data: Data, major: Int) -> String? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let versions = list.compactMap { $0["version"] as? String }.filter { ToolVersion.major($0) == major }
        return ToolVersion.sortedDescending(versions).first.map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
    }

    static func parsePyPI(_ data: Data) -> String? {
        (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["info"] as? [String: Any])?["version"] as? String
    }

    static func parseGitHubRelease(_ data: Data) -> String? {
        guard let tag = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["tag_name"] as? String else {
            return nil
        }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// The stable toolchain line of `rustup check`:
    /// `stable-… - update available: 1.95.0 (…) -> 1.99.0 (…)` → `1.99.0`;
    /// `stable-… - Up to date : 1.95.0 (…)` → `1.95.0`.
    static func parseRustupCheck(_ out: String) -> String? {
        let lines = out.split(whereSeparator: \.isNewline).map(String.init)
        guard let line = lines.first(where: { $0.hasPrefix("stable-") })
            ?? lines.first(where: { !$0.hasPrefix("rustup") && $0.contains(" - ") }) else { return nil }
        if let arrow = line.range(of: "->") { return ToolVersion.parse(String(line[arrow.upperBound...])) }
        guard let colon = line.range(of: ":") else { return nil }
        return ToolVersion.parse(String(line[colon.upperBound...]))
    }
}
