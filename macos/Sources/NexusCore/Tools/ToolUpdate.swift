import Foundation

/// npm package names as the registry allows them: lowercase, optional
/// `@scope/`, no leading `.`/`_`/`-`, ≤ 214 chars. Anything else is refused
/// before it can reach a terminal.
public enum NpmName {
    private static let pattern = try! NSRegularExpression(
        pattern: #"^(@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*$"#)

    public static func isValid(_ name: String) -> Bool {
        guard name.utf8.count <= 214 else { return false }
        return pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }
}

/// The update command for a tool, from a fixed table keyed by install method.
/// It's typed into the user's own terminal (visible, interruptible), so every
/// variable part is validated against a strict pattern first.
public enum ToolUpdate {
    /// nil when there's no command for it (apps that update themselves,
    /// Command Line Tools, manual installs). Throws on a name that fails validation.
    public static func command(for tool: DevTool) throws -> String? {
        switch tool.method {
        case let .brewFormula(name):
            try Validate.formula(name)
            return "brew upgrade \(name)"
        case let .brewCask(name):
            try Validate.formula(name)
            return "brew upgrade --cask \(name)"
        case let .npmGlobal(pkg, _):
            guard NpmName.isValid(pkg) else { throw AppError.invalidName("invalid npm package: \(pkg)") }
            return "npm install -g \(pkg)@latest"
        case .nvm:
            guard let major = tool.version.flatMap(ToolVersion.major) else { return nil }
            return "nvm install \(major) --reinstall-packages-from=current"
        case .claudeNative: return "claude update"
        case .codexStandalone: return "codex update"
        case .rustup: return tool.id == "rust" ? "rustup update" : nil
        case .uvStandalone: return "uv self update"
        case .bunInstaller: return "bun upgrade"
        case .denoInstaller: return "deno upgrade"
        case .homebrewSelf: return "brew update"
        case .commandLineTools, .bundled, .app, .installerPackage, .manual: return nil
        }
    }

    /// One command for "Update all": brew formulae and casks batched into one
    /// `brew upgrade` each, everything else after, run one after another.
    public static func batch(_ tools: [DevTool]) throws -> String? {
        var formulae: [String] = [], casks: [String] = [], rest: [String] = []
        for tool in tools {
            switch tool.method {
            case let .brewFormula(n):
                try Validate.formula(n)
                if !formulae.contains(n) { formulae.append(n) }
            case let .brewCask(n):
                try Validate.formula(n)
                if !casks.contains(n) { casks.append(n) }
            default:
                if let c = try command(for: tool), !rest.contains(c) { rest.append(c) }
            }
        }
        var parts: [String] = []
        if !formulae.isEmpty { parts.append((["brew", "upgrade"] + formulae).joined(separator: " ")) }
        if !casks.isEmpty { parts.append((["brew", "upgrade", "--cask"] + casks).joined(separator: " ")) }
        parts += rest
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}
