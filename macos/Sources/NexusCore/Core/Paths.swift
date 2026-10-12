import Foundation

/// The ONLY place filesystem locations live.
public enum Paths {
    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Same directory the Tauri build used (`app_data_dir` of com.vss.nexusconsole),
    /// so settings, services and sessions carry over with no migration step.
    public static var appData: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.vss.nexusconsole", isDirectory: true)
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
