import Foundation

/// One installed formula or cask. `outdated`/`latestVersion`/`pinned` start
/// false/nil and are filled in by merging `PackagesBackend.outdated()`.
public struct PackageItem: Identifiable, Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable { case formula, cask }

    public var name: String
    public var version: String
    public var kind: Kind
    public var outdated: Bool
    public var latestVersion: String?
    public var pinned: Bool

    /// A formula and a cask can share a name (`docker`), so the kind is part of the id.
    public var id: String { "\(kind.rawValue):\(name)" }

    public init(name: String, version: String, kind: Kind, outdated: Bool = false,
                latestVersion: String? = nil, pinned: Bool = false) {
        self.name = name
        self.version = version
        self.kind = kind
        self.outdated = outdated
        self.latestVersion = latestVersion
        self.pinned = pinned
    }
}

/// Outdated status for one package (`brew outdated --json=v2`).
public struct OutdatedInfo: Equatable, Sendable {
    public var name: String
    public var latestVersion: String?
    public var pinned: Bool
}

/// `brew info --json=v2` for one package, flattened.
public struct PackageDetails: Equatable, Sendable {
    public var name: String
    public var description: String?
    public var homepage: String?
    public var version: String?
    public var dependencies: [String]
    public var isService: Bool
    public var isCask: Bool
}

public enum PackageFilter: String, CaseIterable, Identifiable, Sendable {
    case all, formula, cask, outdated
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: "All"
        case .formula: "Formulae"
        case .cask: "Casks"
        case .outdated: "Outdated"
        }
    }
}

/// Installed packages: list (fast), outdated (slow, separate), info,
/// dependents, upgrade, update. Every write runs under the brew mutation lock.
public final class PackagesBackend: Sendable {
    public let brew: Brew

    public init(brew: Brew) { self.brew = brew }

    // MARK: - Read

    /// The installed list only (`brew list` — fast). Outdated status is fetched
    /// separately by `outdated()` so the table renders without waiting on the
    /// slow `brew outdated`. The two `brew list` calls run concurrently.
    public func list() async throws -> [PackageItem] {
        _ = try brew.bin()
        async let casks = capture(["list", "--cask", "--versions"])
        let formulae = try Self.tolerate(await capture(["list", "--formula", "--versions"]))
        let caskOut = try Self.tolerate(await casks)
        return Self.parseInstalled(formulae: formulae, casks: caskOut)
    }

    /// `brew outdated --json=v2` — slow, may hit the network. Any failure is an
    /// empty list: the table simply shows everything as up to date.
    public func outdated() async throws -> [OutdatedInfo] {
        _ = try brew.bin()
        guard let out = try? await brew.raw(["outdated", "--json=v2"]) else { return [] }
        return Self.parseOutdated(out.out)
    }

    /// Installed formulae that depend on `name` (`brew uses --installed`).
    public func dependents(_ name: String) async throws -> [String] {
        try Validate.formula(name)
        return try await brew.run(["uses", "--installed", name])
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public func info(_ name: String) async throws -> PackageDetails {
        try Validate.formula(name)
        let out = try await brew.run(["info", "--json=v2", name])
        return try Self.parseInfo(out, name: name)
    }

    // MARK: - Write

    public func upgrade(_ name: String) async throws {
        try Validate.formula(name)
        try await brew.mutate(["upgrade", name])
    }

    public func upgradeAll() async throws {
        try await brew.mutate(["upgrade"])
    }

    /// `brew update` — refresh formula definitions (does not upgrade packages).
    public func updateHomebrew() async throws {
        try await brew.mutate(["update"])
    }

    // MARK: - Parsing (pure)

    func capture(_ args: [String]) async -> Result<String, Error> {
        do { return .success(try await brew.run(args)) } catch { return .failure(error) }
    }

    /// `brew list` exits non-zero on an untrusted tap — even when the untrusted
    /// item is an unrelated cask — and its stdout is dropped with it, so the
    /// whole tab silently came back empty. Let that one error through (the UI
    /// offers to trust the tap); every other failure is an empty list, since a
    /// Mac with no casks installed is normal, not an error.
    static func tolerate(_ result: Result<String, Error>) throws -> String {
        switch result {
        case let .success(s): return s
        case let .failure(e):
            if case .untrustedTap? = e as? AppError { throw e }
            return ""
        }
    }

    /// `name version[ version2 …]` → (name, joined versions).
    static func parseInstalledLine<S: StringProtocol>(_ line: S) -> (name: String, version: String)? {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard let name = parts.first else { return nil }
        return (String(name), parts.dropFirst().joined(separator: ", "))
    }

    static func parseInstalled(formulae: String, casks: String) -> [PackageItem] {
        var out: [PackageItem] = []
        for (text, kind) in [(formulae, PackageItem.Kind.formula), (casks, .cask)] {
            for line in text.split(whereSeparator: \.isNewline) {
                guard let (name, version) = parseInstalledLine(line) else { continue }
                out.append(PackageItem(name: name, version: version, kind: kind))
            }
        }
        // Stable sort by name (formula before cask on a tie, as listed).
        return out.enumerated()
            .sorted { ($0.element.name, $0.offset) < ($1.element.name, $1.offset) }
            .map(\.element)
    }

    private struct OutdatedJSON: Decodable {
        struct Entry: Decodable {
            var name: String
            var current_version: String?
            var pinned: Bool?
        }
        var formulae: [Entry]?
        var casks: [Entry]?
    }

    static func parseOutdated(_ json: String) -> [OutdatedInfo] {
        guard let parsed = try? JSONDecoder().decode(OutdatedJSON.self, from: Data(json.utf8)) else { return [] }
        return ((parsed.formulae ?? []) + (parsed.casks ?? [])).map {
            OutdatedInfo(name: $0.name, latestVersion: $0.current_version, pinned: $0.pinned ?? false)
        }
    }

    static func parseInfo(_ json: String, name: String) throws -> PackageDetails {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            throw AppError.parse("brew info json: invalid JSON")
        }
        let item: [String: Any]
        let isCask: Bool
        if let f = (root["formulae"] as? [[String: Any]])?.first {
            (item, isCask) = (f, false)
        } else if let c = (root["casks"] as? [[String: Any]])?.first {
            (item, isCask) = (c, true)
        } else {
            throw AppError.notFound("no info for \(name)")
        }
        let service = item["service"]
        return PackageDetails(
            name: name,
            description: item["desc"] as? String,
            homepage: item["homepage"] as? String,
            version: (item["versions"] as? [String: Any])?["stable"] as? String,
            dependencies: (item["dependencies"] as? [Any])?.compactMap { $0 as? String } ?? [],
            isService: service != nil && !(service is NSNull),
            isCask: isCask
        )
    }

    // MARK: - View-model helpers (pure)

    /// Merge the (background) outdated status onto the installed list. Until it
    /// resolves, packages simply show as up to date.
    public static func merge(_ installed: [PackageItem], outdated: [OutdatedInfo]?) -> [PackageItem] {
        guard let outdated, !outdated.isEmpty else { return installed }
        let byName = Dictionary(outdated.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return installed.map { p in
            guard let o = byName[p.name] else { return p }
            var m = p
            m.outdated = true
            m.latestVersion = o.latestVersion
            m.pinned = o.pinned
            return m
        }
    }

    /// Upgradeable = outdated and not pinned.
    public static func upgradeableCount(_ packages: [PackageItem]) -> Int {
        packages.filter { $0.outdated && !$0.pinned }.count
    }

    public static func filter(_ packages: [PackageItem], query: String, filter: PackageFilter) -> [PackageItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return packages.filter { p in
            switch filter {
            case .formula where p.kind != .formula: return false
            case .cask where p.kind != .cask: return false
            case .outdated where !p.outdated: return false
            default: break
            }
            return q.isEmpty || p.name.lowercased().contains(q)
        }
    }
}
