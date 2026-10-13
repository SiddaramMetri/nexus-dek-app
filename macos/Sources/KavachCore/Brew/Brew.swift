import Foundation

/// Machine/runtime config discovered once at startup. brew* are nil when
/// Homebrew isn't found — the UI degrades to a "not detected" state.
public struct AppContext: Sendable, Equatable {
    public var arch: String
    public var brewPrefix: String?
    public var brewBin: String?

    /// Arch-first prefix probe: Apple Silicon → /opt/homebrew, Intel → /usr/local.
    public static func discover() -> AppContext {
        #if arch(arm64)
        let arch = "aarch64", candidates = ["/opt/homebrew", "/usr/local"]
        #else
        let arch = "x86_64", candidates = ["/usr/local", "/opt/homebrew"]
        #endif
        var all = candidates
        if let env = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"] { all.append(env) }
        for prefix in all where FileManager.default.isExecutableFile(atPath: "\(prefix)/bin/brew") {
            return AppContext(arch: arch, brewPrefix: prefix, brewBin: "\(prefix)/bin/brew")
        }
        return AppContext(arch: arch, brewPrefix: nil, brewBin: nil)
    }
}

/// Homebrew runner + error classification. One instance for the app; its
/// `lock` serializes every brew mutation (the Rust `BrewLock`).
public final class Brew: Sendable {
    public let context: AppContext
    public let lock = AsyncMutex()

    public init(context: AppContext) { self.context = context }

    public static let busyMessage = "Homebrew is busy updating itself. This clears on its own."

    /// Suppresses brew's automatic `brew update` before install/upgrade (a
    /// Finder-launched app doesn't inherit the user's shell env).
    public static let env = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1"]

    public func bin() throws -> String {
        guard let b = context.brewBin else { throw AppError.notFound("Homebrew not found") }
        return b
    }

    public var prefix: String { context.brewPrefix ?? "/opt/homebrew" }

    /// Raw run — caller inspects status.
    public func raw(_ args: [String]) async throws -> ProcOutput {
        try await Proc.run(try bin(), args, env: Self.env)
    }

    /// stdout, or a classified error from stderr.
    @discardableResult
    public func run(_ args: [String]) async throws -> String {
        let out = try await raw(args)
        guard out.ok else { throw Self.classify(stderr: out.err) }
        return out.out
    }

    /// Run while holding the mutation lock.
    @discardableResult
    public func mutate(_ args: [String]) async throws -> String {
        try await lock.withLock { try await self.run(args) }
    }

    /// `brew --version` → "6.0.10". Off the startup path (costs 100–500ms).
    public func version() async -> String? {
        guard let out = try? await raw(["--version"]), out.ok else { return nil }
        let first = out.out.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let v = first.replacingOccurrences(of: "Homebrew", with: "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    // MARK: - stderr classification

    static let busyMarkers = ["already locked", "vendor-install", "Portable Ruby", "is already running"]
    static let untrustedMarker = "from untrusted tap "
    static let maxErrLines = 3

    /// Lock/Ruby-upgrade noise → `busy`; untrusted tap → `untrustedTap`;
    /// everything else → a short `shell` message with the Ruby backtrace stripped.
    public static func classify(stderr: String) -> AppError {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if busyMarkers.contains(where: text.contains) { return .busy(busyMessage) }
        if let tap = untrustedTap(text) { return .untrustedTap(tap) }
        return .shell(userFacing(text))
    }

    static func untrustedTap(_ stderr: String) -> String? {
        guard let r = stderr.range(of: untrustedMarker) else { return nil }
        guard let word = stderr[r.upperBound...].split(whereSeparator: \.isWhitespace).first else { return nil }
        var tap = String(word)
        while tap.hasSuffix(".") { tap.removeLast() }
        return (try? Validate.tap(tap)) != nil ? tap : nil
    }

    static func userFacing(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !($0.contains(".rb:") && $0.contains(":in ")) }
            .filter { !$0.hasPrefix("Please report this issue") }
            .prefix(maxErrLines)
        return lines.isEmpty ? "Homebrew command failed" : lines.joined(separator: " ")
    }
}
