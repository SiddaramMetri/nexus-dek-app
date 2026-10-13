import Foundation

/// The ONLY place filesystem locations live.
public enum Paths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Kavach Console's own data folder (settings, services, history, caches).
    public static var appData: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppInfo.bundleID, isDirectory: true)
    }

    /// Where the app kept its data under its old name (and the Tauri build).
    static var legacyAppData: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.vss.nexusconsole", isDirectory: true)
    }

    /// One-time, copy-only move to the new name: files missing from the new
    /// folder are copied from the old one, which is left untouched.
    public static func migrateLegacyData() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: legacyAppData.path) else { return }
        try? fm.createDirectory(at: appData, withIntermediateDirectories: true)
        for name in names where name.hasSuffix(".json") {
            let dest = appData.appendingPathComponent(name)
            guard !fm.fileExists(atPath: dest.path) else { continue }
            try? fm.copyItem(at: legacyAppData.appendingPathComponent(name), to: dest)
        }
    }

    public static var claudeProjects: URL { home.appendingPathComponent(".claude/projects", isDirectory: true) }
    public static var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    /// `~/claude-history-archive/<project>/…` + INDEX.md + journal.jsonl.
    public static var archiveRoot: URL { home.appendingPathComponent("claude-history-archive", isDirectory: true) }

    // Stable VSCode only.
    public static var vscodeUser: URL { home.appendingPathComponent("Library/Application Support/Code/User", isDirectory: true) }
    public static var vscodeWorkspaceStorage: URL { vscodeUser.appendingPathComponent("workspaceStorage", isDirectory: true) }
    public static var vscodeGlobalStateDB: URL { vscodeUser.appendingPathComponent("globalStorage/state.vscdb") }
    public static var vscodeExtensions: URL { home.appendingPathComponent(".vscode/extensions", isDirectory: true) }
}
