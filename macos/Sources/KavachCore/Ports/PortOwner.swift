import Darwin
import Foundation

/// What a listening process belongs to — decides the section it renders in.
public enum PortOwner: Hashable, Sendable {
    /// A dev server inside one of the user's projects (absolute project root).
    case project(root: String)
    /// A macOS app; the outermost `.app` bundle in its executable path.
    case app(bundlePath: String)
    /// Part of macOS itself — never killable from here.
    case system
    /// Neither (a Homebrew daemon, a global CLI tool, a root process ps can't read).
    case other
}

/// Pure classification: executable path → system / app, and cwd + argv →
/// project directory. Filesystem reads are limited to existence checks and the
/// project-root walk in `JunkGrouping`.
public enum PortClassifier {
    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"]

    /// Path components that mean "inside a dependency or build folder", never
    /// the project itself: `<proj>/node_modules/.bin/next` → `<proj>`.
    static let cutComponents: Set<String> = [
        "node_modules", ".venv", "venv", "site-packages", "vendor", ".bin", ".next", ".nuxt", "target", "dist", "build",
    ]

    /// Top-level folders in home that hold tools and app data, not projects.
    static let nonProjectRoots: Set<String> = ["Library", "Applications", ".Trash"]

    public static func classify(executable: String?, cwd: String?, commandLine: String?, home: URL) -> PortOwner {
        if let exe = executable {
            if isSystem(executable: exe) { return .system }
            if let bundle = appBundle(executable: exe) { return .app(bundlePath: bundle) }
        }
        if let dir = projectDirectory(cwd: cwd, commandLine: commandLine, home: home.standardizedFileURL.path) {
            let root = JunkGrouping.root(forProject: URL(fileURLWithPath: dir, isDirectory: true), home: home)
            if isProjectPath(root.path, home: home.standardizedFileURL.path) { return .project(root: root.path) }
        }
        return .other
    }

    public static func isSystem(executable: String) -> Bool {
        systemPrefixes.contains { executable.hasPrefix($0) }
    }

    /// `/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/…`
    /// → `/Applications/Visual Studio Code.app`.
    public static func appBundle(executable: String) -> String? {
        guard executable.hasPrefix("/") else { return nil }
        var path = ""
        for component in executable.split(separator: "/") {
            path += "/" + component
            if component.hasSuffix(".app") { return path }
        }
        return nil
    }

    /// "Visual Studio Code" for `/Applications/Visual Studio Code.app` — the
    /// name Finder shows, which is friendlier than CFBundleName ("Code").
    public static func appName(bundlePath: String) -> String {
        let file = (bundlePath as NSString).lastPathComponent
        return file.hasSuffix(".app") ? String(file.dropLast(4)) : file
    }

    /// The process's project directory: its cwd when that is inside home,
    /// otherwise the first existing path inside home on its command line
    /// (`node ~/Documents/api/server.js` started from `/`).
    static func projectDirectory(cwd: String?, commandLine: String?, home: String) -> String? {
        if let cwd, let dir = usableDirectory(cwd, home: home) { return dir }
        for token in pathTokens(commandLine ?? "") {
            if let dir = usableDirectory(token, home: home) { return dir }
        }
        return nil
    }

    /// Absolute paths on a command line, including `--flag=/path` values.
    /// Splits on whitespace, so a path with spaces is missed (ps flattens argv).
    static func pathTokens(_ commandLine: String) -> [String] {
        commandLine.split(whereSeparator: \.isWhitespace).compactMap { raw -> String? in
            var token = Substring(raw)
            if let eq = token.firstIndex(of: "="), token.first == "-" { token = token[token.index(after: eq)...] }
            token = token.drop { $0 == "'" || $0 == "\"" }
            while let last = token.last, last == "'" || last == "\"" || last == "," { token = token.dropLast() }
            return token.hasPrefix("/") ? String(token) : nil
        }
    }

    /// A path inside home, cut back above any dependency folder, that isn't a
    /// tool install (`~/.nvm/…`, `~/.local/…`) or `~/Library`. Files map to
    /// their folder; paths that don't exist are ignored.
    static func usableDirectory(_ path: String, home: String) -> String? {
        let standardized = (path as NSString).standardizingPath
        guard standardized.hasPrefix(home + "/") else { return nil }
        let rel = standardized.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        var kept: [String] = []
        for c in rel {
            if cutComponents.contains(c) { break }
            if c.hasPrefix(".") { return nil }
            kept.append(c)
        }
        guard let first = kept.first, !nonProjectRoots.contains(first) else { return nil }
        var dir = home + "/" + kept.joined(separator: "/")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue { dir = (dir as NSString).deletingLastPathComponent }
        return isProjectPath(dir, home: home) ? dir : nil
    }

    /// Not home, not a bare container folder (`~/Documents`).
    static func isProjectPath(_ path: String, home: String) -> Bool {
        guard path.hasPrefix(home + "/") else { return false }
        let rel = path.dropFirst(home.count + 1)
        if !rel.contains("/"), JunkGrouping.containerNames.contains(String(rel)) { return false }
        return !rel.isEmpty
    }

    /// Exact executable path via proc_pidpath (no subprocess). nil when the
    /// process is gone or not inspectable.
    public static func executablePath(pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    // MARK: - macOS process names

    public struct SystemName: Equatable, Sendable {
        public let title: String
        public let note: String?
    }

    /// Friendly names for the macOS daemons people actually find on their ports.
    public static func systemName(command: String) -> SystemName {
        switch command {
        case "ControlCenter":
            SystemName(title: "AirPlay Receiver", note: "Ports 5000 and 7000 are used by AirPlay Receiver. "
                + "To free them, turn it off in System Settings → General → AirDrop & Handoff.")
        case "rapportd":
            SystemName(title: "Handoff & Continuity", note: nil)
        default:
            SystemName(title: command, note: nil)
        }
    }
}

/// Current git branch straight from `.git/HEAD` — no git subprocess.
public enum GitHead {
    /// "main", or a short sha when detached. Follows `.git` files (worktrees, submodules).
    public static func branch(atRoot root: String) -> String? {
        let dotGit = (root as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }
        var gitDir = dotGit
        if !isDir.boolValue {
            guard let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  let line = pointer.split(whereSeparator: \.isNewline).first,
                  line.hasPrefix("gitdir:") else { return nil }
            let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDir = target.hasPrefix("/") ? target : (root as NSString).appendingPathComponent(target)
        }
        guard let head = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("HEAD"), encoding: .utf8)
        else { return nil }
        return parseHead(head)
    }

    static func parseHead(_ head: String) -> String? {
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref:") {
            let ref = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        }
        guard line.count >= 7, line.allSatisfy(\.isHexDigit) else { return nil }
        return String(line.prefix(7))
    }
}
