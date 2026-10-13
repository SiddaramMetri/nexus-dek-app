import Foundation

/// Detects installed tools: every catalog entry probed in parallel, each
/// `--version` under a timeout. Read-only — never launches an app.
public enum ToolDetector {
    public static let versionTimeout: Duration = .seconds(5)

    /// Env for every probe: a PATH that finds node for `#!/usr/bin/env node`
    /// scripts, and no update nags or background self-updates.
    static func env(_ locator: ToolLocator, _ extra: [String: String] = [:]) -> [String: String] {
        ["PATH": locator.pathEnv, "NO_UPDATE_NOTIFIER": "1", "npm_config_update_notifier": "false",
         "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1"].merging(extra) { _, new in new }
    }

    /// `body`'s result, or nil once `timeout` passes. Cancelling the body kills
    /// its subprocess (`Proc.run` terminates on cancellation).
    public static func withTimeout<T: Sendable>(_ timeout: Duration,
                                                _ body: @escaping @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// stdout (or stderr when stdout is empty — `java -version`), any exit status.
    static func capture(_ path: String, _ args: [String], env: [String: String],
                        timeout: Duration = versionTimeout) async -> String? {
        await withTimeout(timeout) {
            guard let r = try? await Proc.run(path, args, env: env) else { return nil }
            let out = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? r.err : r.out
        }
    }

    public static func detectAll(locator: ToolLocator = ToolLocator()) async -> [DevTool] {
        let specs = ToolCatalog.all
        let found = await withTaskGroup(of: (Int, DevTool?).self) { group in
            for (i, spec) in specs.enumerated() {
                group.addTask { (i, await detect(spec, locator: locator)) }
            }
            var out: [(Int, DevTool)] = []
            for await (i, tool) in group { if let tool { out.append((i, tool)) } }
            return out
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    public static func detect(_ spec: ToolSpec, locator: ToolLocator) async -> DevTool? {
        spec.kind == .app ? detectApp(spec, locator: locator) : await detectCLI(spec, locator: locator)
    }

    static func detectCLI(_ spec: ToolSpec, locator: ToolLocator) async -> DevTool? {
        guard let binary = spec.binary, let path = locator.find(binary) else { return nil }
        let env = env(locator, spec.versionEnv)
        async let details = details(for: spec.id, path: path, locator: locator, env: env)
        async let methodSource = installSource(spec.id, path: path, env: env)
        let output = await capture(path, spec.versionArgs, env: env)
        let resolved = await methodSource
        return DevTool(
            id: spec.id, name: spec.name, kind: .cli, symbol: spec.symbol,
            version: output.flatMap(ToolVersion.parse),
            path: path, resolvedPath: resolved,
            method: InstallMethod.detect(toolID: spec.id, link: path, resolved: resolved, home: locator.home),
            details: await details,
            releaseNotes: spec.releaseNotes.flatMap(URL.init(string:)))
    }

    /// The path the install method is read from. `/usr/bin/java` is a
    /// dispatcher, so for Java it's the active JDK home instead.
    static func installSource(_ id: String, path: String, env: [String: String]) async -> String {
        if id == "java", path == "/usr/bin/java",
           let home = await capture("/usr/libexec/java_home", [], env: env)?
               .trimmingCharacters(in: .whitespacesAndNewlines), home.hasPrefix("/") {
            return ToolLocator.resolve(home)
        }
        return ToolLocator.resolve(path)
    }

    /// Secondary lines under the version: Rust's cargo/rustup, other nvm Nodes.
    static func details(for id: String, path: String, locator: ToolLocator, env: [String: String]) async -> [String] {
        switch id {
        case "rust":
            let dir = (path as NSString).deletingLastPathComponent
            async let cargo = capture("\(dir)/cargo", ["--version"], env: env)
            async let rustup = capture("\(dir)/rustup", ["--version"], env: env)
            var out: [String] = []
            if let v = await cargo.flatMap(ToolVersion.parse) { out.append("cargo \(v)") }
            if let v = await rustup.flatMap(ToolVersion.parse) { out.append("rustup \(v)") }
            return out
        case "node":
            let active = ToolLocator.resolve(path)
            let others = ToolLocator.nvmVersions(home: locator.home).filter { !active.contains("/node/\($0)/") }
            return others.isEmpty ? [] : ["Also via nvm: " + others.joined(separator: ", ")]
        default:
            return []
        }
    }

    public static let appDirs = ["/Applications", "\(Paths.home.path)/Applications"]

    /// Version from the bundle's Info.plist — the app is never launched.
    static func detectApp(_ spec: ToolSpec, locator: ToolLocator) -> DevTool? {
        let fm = FileManager.default
        for dir in appDirs {
            for bundle in spec.bundles {
                let path = "\(dir)/\(bundle)"
                guard fm.fileExists(atPath: path) else { continue }
                let plist = NSDictionary(contentsOfFile: "\(path)/Contents/Info.plist")
                let version = plist?["CFBundleShortVersionString"] as? String
                return DevTool(
                    id: spec.id, name: spec.name, kind: .app, symbol: spec.symbol,
                    version: version?.trimmingCharacters(in: .whitespaces),
                    path: path, resolvedPath: ToolLocator.resolve(path),
                    method: appMethod(spec, brewPrefix: locator.brewPrefix),
                    releaseNotes: spec.releaseNotes.flatMap(URL.init(string:)))
            }
        }
        return nil
    }

    /// A cask install is upgraded by brew; anything else updates itself.
    static func appMethod(_ spec: ToolSpec, brewPrefix: String?) -> InstallMethod {
        guard let brewPrefix else { return .app }
        let tokens = [spec.cask].compactMap { $0 } + (spec.id == "docker-desktop" ? ["docker"] : [])
        for t in tokens where FileManager.default.fileExists(atPath: "\(brewPrefix)/Caskroom/\(t)") {
            return .brewCask(t)
        }
        return .app
    }
}
