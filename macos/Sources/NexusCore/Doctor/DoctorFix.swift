import Foundation

/// How the UI presents a finding's fix button. Purely presentational — the
/// fix itself re-validates its target in `DoctorFix.run`.
public struct FixMeta: Equatable, Sendable {
    public let label: String

    /// Delete/Clear/Uninstall fixes get danger styling.
    public var destructive: Bool {
        ["Delete", "Clear", "Uninstall"].contains { label.hasPrefix($0) }
    }
}

/// The fix runner. Every fix re-scans its own targets and destructive ones
/// confirm HERE, before mutating, so the UI can never bypass the confirm; the
/// UI never supplies paths, only a fix id from a finding.
public enum DoctorFix {
    private static let labels: [String: String] = [
        "vscode_cleanup_orphans": "Delete orphan caches",
        "vscode_vacuum": "VACUUM now",
        "deep_dead_node_modules": "Delete dead node_modules",
        "deep_stale_node_modules": "Delete stale node_modules",
        "pnpm_orphan_stores": "Delete old pnpm stores",
        "cache_npm": "Clear cache",
        "cache_uv": "Clear cache",
        "cache_huggingface": "Clear cache",
        "cache_puppeteer": "Clear cache",
        "cache_gradle": "Clear cache",
        "cache_deriveddata": "Clear cache",
    ]

    /// finding.fix id → its button, or nil for an unknown id (no button).
    public static func meta(_ fixId: String?) -> FixMeta? {
        guard let fixId else { return nil }
        // Parameterized fixes: the parameter is validated at fix time.
        if fixId.hasPrefix("ollama_rm:") { return FixMeta(label: "Delete model") }
        if fixId.hasPrefix("browser_cache:") { return FixMeta(label: "Clear cache") }
        if fixId.hasPrefix("vscode_ext_rm:") { return FixMeta(label: "Uninstall") }
        // browser_ext_manage:<browser>:<id> — non-destructive, opens its own page.
        if fixId.hasPrefix("browser_ext_manage:") {
            let parts = fixId.split(separator: ":", omittingEmptySubsequences: false)
            return FixMeta(label: "Manage in \(parts.count > 1 ? String(parts[1]) : "")")
        }
        return labels[fixId].map(FixMeta.init)
    }

    /// Run a fix and return its before/after summary line. Throws
    /// `.cancelled` when the user dismisses the confirm.
    public static func run(_ fixId: String, confirmer: Confirmer) async throws -> String {
        if let model = strip(fixId, "ollama_rm:") {
            let c = OllamaProbe.fixConfirmation(model)
            try await confirmer.require(title: c.title, message: c.message, action: "Delete", destructive: true)
            return try await OllamaProbe.deleteModel(model)
        }
        if let label = strip(fixId, "browser_cache:") {
            let c = BrowserProbes.fixConfirmation(label)
            try await confirmer.require(title: c.title, message: c.message, action: "Clear", destructive: true)
            return try await BrowserProbes.clearCache(label)
        }
        // Non-destructive: just opens the browser's own extensions page.
        if let spec = strip(fixId, "browser_ext_manage:") {
            return try await BrowserProbes.manageExtension(spec)
        }
        // VSCode fixes confirm inside the VSCode port.
        if let id = strip(fixId, "vscode_ext_rm:") {
            return try await VSCodeDoctor.uninstallExtension(id, confirmer: confirmer)
        }
        switch fixId {
        case "vscode_cleanup_orphans": return try await VSCodeDoctor.cleanupOrphans(confirmer: confirmer)
        case "vscode_vacuum": return try await VSCodeDoctor.vacuum(confirmer: confirmer)
        default: break
        }
        if let c = await DeepScan.fixConfirmation(fixId) {
            try await confirmer.require(title: c.title, message: c.message, action: "Delete", destructive: true)
        }
        return try await DeepScan.fix(fixId)
    }

    private static func strip(_ s: String, _ prefix: String) -> String? {
        s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : nil
    }

    /// The mutation audit trail (journal.jsonl), newest first.
    public static func journal() async -> [Journal.Entry] {
        await Task.detached { Journal.read(limit: 200) }.value
    }
}
