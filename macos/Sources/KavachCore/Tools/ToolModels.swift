import Foundation

public enum ToolKind: String, Codable, Sendable { case cli, app }

/// How a tool got onto this Mac, read from where its binary really lives.
/// Decides both where "latest" comes from and which update command is offered.
public enum InstallMethod: Equatable, Hashable, Sendable {
    case brewFormula(String)
    case brewCask(String)
    /// `npm install -g` — package name from the `lib/node_modules/<pkg>` path.
    case npmGlobal(package: String, nvm: Bool)
    /// A Node.js version managed by nvm (the `node` binary itself).
    case nvm
    case claudeNative
    case codexStandalone
    case rustup
    case uvStandalone
    case bunInstaller
    case denoInstaller
    case homebrewSelf
    /// `/usr/bin` + Xcode Command Line Tools — macOS Software Update owns it.
    case commandLineTools
    /// Shipped inside another app's bundle (`Docker.app/…/bin/docker`).
    case bundled(app: String)
    case app
    /// A `.pkg` installer dropped it under `/usr/local`.
    case installerPackage
    case manual

    public var label: String {
        switch self {
        case let .brewFormula(n): "Homebrew · \(n)"
        case let .brewCask(n): "Homebrew cask · \(n)"
        case let .npmGlobal(p, nvm): nvm ? "npm global (nvm) · \(p)" : "npm global · \(p)"
        case .nvm: "nvm"
        case .claudeNative: "Native installer"
        case .codexStandalone: "Standalone installer"
        case .rustup: "rustup"
        case .uvStandalone: "Standalone installer"
        case .bunInstaller: "bun installer"
        case .denoInstaller: "deno installer"
        case .homebrewSelf: "Homebrew"
        case .commandLineTools: "Command Line Tools"
        case let .bundled(app): "Bundled with \(app)"
        case .app: "Mac app"
        case .installerPackage: "Installer package"
        case .manual: "Manual install"
        }
    }

    /// Stable key for caching latest-version results; changes when the
    /// install method does, so a switch from npm to brew re-checks.
    public var key: String {
        switch self {
        case let .brewFormula(n): "brew:\(n)"
        case let .brewCask(n): "cask:\(n)"
        case let .npmGlobal(p, _): "npm:\(p)"
        case let .bundled(app): "bundled:\(app)"
        default: String(describing: self)
        }
    }

    public var isBrew: Bool {
        switch self {
        case .brewFormula, .brewCask: true
        default: false
        }
    }
}

/// One installed developer tool.
public struct DevTool: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: ToolKind
    public let symbol: String
    /// Parsed version (`2.1.296`), nil when `--version` gave nothing usable.
    public var version: String?
    /// Where it was found (the PATH entry or the `.app`).
    public var path: String
    /// `path` with symlinks resolved — what the install method was read from.
    public var resolvedPath: String
    public var method: InstallMethod
    /// Secondary lines: `cargo 1.95.0`, other nvm versions…
    public var details: [String]
    public var releaseNotes: URL?

    public init(id: String, name: String, kind: ToolKind, symbol: String, version: String?, path: String,
                resolvedPath: String, method: InstallMethod, details: [String] = [], releaseNotes: URL? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.symbol = symbol
        self.version = version
        self.path = path
        self.resolvedPath = resolvedPath
        self.method = method
        self.details = details
        self.releaseNotes = releaseNotes
    }

    /// Cache key for this tool's latest-version result.
    public var latestKey: String { "\(id)|\(method.key)" }
}

/// One latest-version lookup, persisted between launches.
public struct LatestRecord: Codable, Equatable, Sendable {
    public var latest: String?
    /// Set by `brew outdated`, which reports outdated items only.
    public var outdated: Bool?
    /// "Updates itself" etc. — there is nothing to compare.
    public var note: String?
    public var at: Date

    public init(latest: String? = nil, outdated: Bool? = nil, note: String? = nil, at: Date = Date()) {
        self.latest = latest
        self.outdated = outdated
        self.note = note
        self.at = at
    }

    public static func failed(at: Date = Date()) -> LatestRecord { LatestRecord(at: at) }
}

/// The persisted cache: last check time + one record per `DevTool.latestKey`.
public struct ToolsUpdateCache: Codable, Equatable, Sendable {
    public var checkedAt: Date?
    public var records: [String: LatestRecord]

    public init(checkedAt: Date? = nil, records: [String: LatestRecord] = [:]) {
        self.checkedAt = checkedAt
        self.records = records
    }

    public static let store = JSONStore<ToolsUpdateCache>(file: "tools.json", key: "updates")
    /// Automatic checks run at most this often; "Check for updates" ignores it.
    public static let autoCheckInterval: TimeInterval = 24 * 60 * 60

    public func isDue(now: Date = Date()) -> Bool {
        guard let checkedAt else { return true }
        return now.timeIntervalSince(checkedAt) >= Self.autoCheckInterval
    }
}

public enum ToolStatus: Equatable, Sendable {
    case unchecked
    case upToDate
    case updateAvailable(String?)
    case managed(String)
    case couldntCheck

    public var label: String {
        switch self {
        case .unchecked: "Not checked"
        case .upToDate: "Up to date"
        case .updateAvailable: "Update available"
        case let .managed(note): note
        case .couldntCheck: "Couldn't check"
        }
    }

    public var hasUpdate: Bool {
        if case .updateAvailable = self { return true }
        return false
    }

    /// Fold the installed version and a latest record into one status.
    public static func resolve(installed: String?, record: LatestRecord?) -> ToolStatus {
        guard let record else { return .unchecked }
        if let note = record.note { return .managed(note) }
        if let latest = record.latest, let installed, let c = ToolVersion.compare(installed, latest) {
            return c < 0 ? .updateAvailable(latest) : .upToDate
        }
        if let outdated = record.outdated { return outdated ? .updateAvailable(record.latest) : .upToDate }
        return .couldntCheck
    }
}

public enum ToolFilter: String, CaseIterable, Identifiable, Sendable {
    case all, updates, clis, apps
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: "All"
        case .updates: "Updates"
        case .clis: "CLIs"
        case .apps: "Apps"
        }
    }

    public func matches(_ tool: DevTool, status: ToolStatus, query: String) -> Bool {
        switch self {
        case .updates where !status.hasUpdate: return false
        case .clis where tool.kind != .cli: return false
        case .apps where tool.kind != .app: return false
        default: break
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || tool.name.lowercased().contains(q) || tool.method.label.lowercased().contains(q)
    }
}
