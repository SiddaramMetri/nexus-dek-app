import Foundation

/// VSCode Doctor: three read-only probes + three confirm-gated fixes (the Rust
/// `doctor::vscode` + `commands::vscode`). Fixes take no paths — each re-scans
/// at fix time — and every confirm happens here, so the UI can't skip it.
public enum VSCodeDoctor {
    /// workspaceStorage dirs whose project folder is gone.
    public static let orphans = Probe(id: VSCodeProbes.orphansId, scope: .vscode,
                                      available: { VSCodeProbes.available() }) { VSCodeProbes.runOrphans() }
    /// state.vscdb files carrying reclaimable free pages.
    public static let dbBloat = Probe(id: VSCodeProbes.dbBloatId, scope: .vscode,
                                      available: { VSCodeProbes.available() }) { VSCodeProbes.runDBBloat() }
    /// Static package.json scan of installed extensions.
    public static let extensionAudit = Probe(id: VSCodeExtensions.auditId, scope: .vscode,
                                             available: { VSCodeExtensions.available() }) { VSCodeExtensions.run() }

    /// Is VSCode holding any state.vscdb open?
    public static func stateDBsInUse() async -> Bool { await VSCodeProcess.stateDBsInUse() }

    /// Confirm, then delete workspaceStorage caches whose project folder is gone.
    public static func cleanupOrphans(confirmer: Confirmer) async throws -> String {
        try await confirmer.require(
            title: "Delete orphan VSCode caches?",
            message: "These caches belong to project folders that no longer exist — nothing can use them again.",
            action: "Delete", destructive: true)
        return try VSCodeProbes.cleanupOrphans()
    }

    /// Confirm (wording names the force-quit when VSCode is open), then VACUUM
    /// bloated DBs. The kill only ever happens behind the wording that names it.
    public static func vacuum(confirmer: Confirmer) async throws -> String {
        let busy = await stateDBsInUse()
        try await confirmer.require(
            title: busy ? "VSCode is open — close it and VACUUM?" : "VACUUM VSCode databases?",
            message: busy
                ? "VSCode is holding these databases open, so it will be closed now — unsaved changes in open "
                    + "editors may be lost. Then the rebuild runs; nothing is deleted."
                : "Rebuilds bloated state.vscdb files compactly, in place — nothing is deleted.",
            action: busy ? "Close VSCode & VACUUM" : "VACUUM",
            destructive: busy)
        if busy { try await VSCodeProcess.forceQuit() }
        return try await vacuumBloated()
    }

    /// Unconfirmed VACUUM for the opt-in tray scheduler. Refuses while VSCode
    /// holds the DBs. VACUUM is atomic and content-preserving — the one DB write
    /// done without a copy first (a .bak of a 1 GB file would double the problem).
    public static func vacuumBloated() async throws -> String {
        if await stateDBsInUse() { throw AppError.forbidden("Close VSCode first — it holds these databases open.") }
        return VSCodeProbes.vacuumBloated(VSCodeProbes.allStateDBs())
    }

    /// Confirm, then uninstall one extension (`vscode_ext_rm:<id>` fix).
    public static func uninstallExtension(_ id: String, confirmer: Confirmer) async throws -> String {
        let c = VSCodeExtensions.confirmation(id)
        try await confirmer.require(title: c.title, message: c.message, action: "Uninstall", destructive: true)
        return try await VSCodeExtensions.uninstall(id)
    }

    /// Bytes → "60 MB" / "2.2 GB" (the Rust `fmt_mb`).
    public static func fmtMB(_ bytes: UInt64) -> String { VSCodeProbes.fmtMB(bytes) }
}
