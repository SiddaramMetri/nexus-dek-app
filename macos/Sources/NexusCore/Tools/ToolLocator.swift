import Foundation

/// Finds CLIs without a login shell (a Finder-launched app's PATH is
/// minimal) by probing the directories version managers and installers use.
public struct ToolLocator: Sendable {
    public let home: String
    /// Homebrew's prefix, for Caskroom lookups.
    public let brewPrefix: String?
    /// The active nvm `bin` dir (default alias, else newest), resolved once.
    public let nvmBin: String?
    let hasCommandLineTools: Bool

    public init(home: String = Paths.home.path, brewPrefix: String? = AppContext.discover().brewPrefix) {
        self.home = home
        self.brewPrefix = brewPrefix
        nvmBin = Self.nvmDefault(home: home).map { "\(home)/.nvm/versions/node/\($0)/bin" }
        let fm = FileManager.default
        hasCommandLineTools = fm.fileExists(atPath: "/Library/Developer/CommandLineTools")
            || fm.fileExists(atPath: "/Applications/Xcode.app")
    }

    /// User-level managers first (their installers prepend to PATH), then
    /// Homebrew, then system dirs — the order a typical shell resolves in.
    public var searchDirs: [String] {
        var dirs = ["\(home)/.local/bin"]
        if let nvmBin { dirs.append(nvmBin) }
        dirs += ["\(home)/.bun/bin", "\(home)/.deno/bin", "\(home)/.cargo/bin",
                 "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/Library/pnpm", "/usr/bin"]
        return dirs
    }

    /// PATH for child processes, so `#!/usr/bin/env node` scripts find node.
    public var pathEnv: String { (searchDirs + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":") }

    /// First executable named `binary` in `searchDirs`. `/usr/bin` shims that
    /// would pop the "install developer tools" dialog are skipped.
    public func find(_ binary: String) -> String? {
        let fm = FileManager.default
        for dir in searchDirs {
            let path = "\(dir)/\(binary)"
            guard fm.isExecutableFile(atPath: path) else { continue }
            if dir == "/usr/bin", !systemBinaryUsable(binary) { continue }
            return path
        }
        return nil
    }

    func systemBinaryUsable(_ binary: String) -> Bool {
        if binary == "java" { return !Self.installedJDKs(home: home).isEmpty }
        return hasCommandLineTools
    }

    /// `.jdk` bundles in the system and user JavaVirtualMachines dirs — no
    /// JDK means `/usr/bin/java` is only the "install Java" stub.
    static func installedJDKs(home: String) -> [String] {
        ["/Library/Java/JavaVirtualMachines", "\(home)/Library/Java/JavaVirtualMachines"].flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasSuffix(".jdk") }.map { "\(dir)/\($0)" }
        }
    }

    public static func resolve(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    // MARK: - nvm

    /// Installed nvm versions (`v22.18.0`), newest first.
    public static func nvmVersions(home: String) -> [String] {
        let dir = "\(home)/.nvm/versions/node"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("v") }
        return ToolVersion.sortedDescending(names)
    }

    /// The version `~/.nvm/alias/default` points at, following alias chains
    /// (`lts/*` → `lts/jod` → `v22.18.0`); else the newest installed.
    static func nvmDefault(home: String) -> String? {
        let versions = nvmVersions(home: home)
        guard !versions.isEmpty else { return nil }
        let aliasDir = "\(home)/.nvm/alias"
        var alias = (try? String(contentsOfFile: "\(aliasDir)/default", encoding: .utf8)) ?? ""
        for _ in 0 ..< 6 {
            let a = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !a.isEmpty else { break }
            if let v = matchNvmVersion(a, versions) { return v }
            guard !a.contains(".."), let next = try? String(contentsOfFile: "\(aliasDir)/\(a)", encoding: .utf8) else { break }
            alias = next
        }
        return versions.first
    }

    /// `v22.18.0`, `22.18.0`, `22`, `node`/`stable` → the newest installed match.
    static func matchNvmVersion(_ alias: String, _ versions: [String]) -> String? {
        if alias == "node" || alias == "stable" { return versions.first }
        let bare = alias.hasPrefix("v") ? String(alias.dropFirst()) : alias
        guard bare.first?.isNumber == true else { return nil }
        return versions.first { v in
            let vb = v.dropFirst()
            return vb == bare || vb.hasPrefix(bare + ".")
        }
    }
}

// MARK: - Install method

extension InstallMethod {
    /// Read the install method from where the binary really lives.
    /// `link` is the PATH entry, `resolved` the symlink-resolved target.
    public static func detect(toolID: String, link: String, resolved: String, home: String) -> InstallMethod {
        if toolID == "brew" { return .homebrewSelf }
        if let name = segment(after: "/Caskroom/", in: resolved) { return .brewCask(name) }
        if let name = segment(after: "/Cellar/", in: resolved) { return .brewFormula(name) }
        if let app = appName(in: resolved) { return .bundled(app: app) }
        if let pkg = npmPackage(in: resolved) { return .npmGlobal(package: pkg, nvm: resolved.contains("/.nvm/")) }
        if resolved.contains("/.nvm/versions/node/") { return .nvm }
        if resolved.hasPrefix("\(home)/.local/share/claude/") || link == "\(home)/.local/bin/claude" { return .claudeNative }
        if resolved.contains("/.codex/packages/standalone/") { return .codexStandalone }
        if resolved.hasPrefix("\(home)/.cargo/bin/") || resolved.hasPrefix("\(home)/.rustup/") { return .rustup }
        if resolved.hasPrefix("\(home)/.bun/") { return .bunInstaller }
        if resolved.hasPrefix("\(home)/.deno/") { return .denoInstaller }
        if toolID == "uv", link.hasPrefix("\(home)/.local/bin/") || resolved.hasPrefix("\(home)/.local/bin/") {
            return .uvStandalone
        }
        if resolved.hasPrefix("/usr/bin/") || resolved.hasPrefix("/Library/Developer/CommandLineTools/")
            || resolved.hasPrefix("/Applications/Xcode") {
            return .commandLineTools
        }
        if resolved.hasPrefix("/usr/local/") || resolved.hasPrefix("/Library/") { return .installerPackage }
        return .manual
    }

    /// `/opt/homebrew/Cellar/python@3.14/3.14.4_1/bin/python3` → `python@3.14`.
    static func segment(after marker: String, in path: String) -> String? {
        guard let r = path.range(of: marker) else { return nil }
        let name = path[r.upperBound...].split(separator: "/").first.map(String.init)
        return name?.isEmpty == false ? name : nil
    }

    /// `/Applications/Docker.app/Contents/Resources/bin/docker` → `Docker`.
    static func appName(in path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return path[..<r.lowerBound].split(separator: "/").last.map(String.init)
    }

    /// `…/lib/node_modules/@anthropic-ai/claude-code/cli.js` → `@anthropic-ai/claude-code`.
    static func npmPackage(in path: String) -> String? {
        guard let r = path.range(of: "/lib/node_modules/", options: .backwards) else { return nil }
        let segs = path[r.upperBound...].split(separator: "/")
        guard let first = segs.first else { return nil }
        if first.hasPrefix("@") {
            guard segs.count > 1 else { return nil }
            return "\(first)/\(segs[1])"
        }
        return String(first)
    }
}
