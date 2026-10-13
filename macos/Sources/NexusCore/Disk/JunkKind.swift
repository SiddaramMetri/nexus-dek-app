import Foundation

/// A kind of regenerable dev folder the cleaner may remove. Each kind is
/// matched by folder name AND a marker that proves what it is (a manifest next
/// to it, a gitignore entry, a venv config inside), so an ordinary project
/// folder that happens to be called `build` or `target` is never offered.
public enum JunkKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case nodeModules
    case jsFrameworkCache
    case jsBuildOutput
    case rustTarget
    case pythonVenv
    case cocoaPods
    case gradleCache

    public var id: String { rawValue }

    /// Folder names `find` looks for.
    public var folderNames: [String] {
        switch self {
        case .nodeModules: ["node_modules"]
        case .jsFrameworkCache: [".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".angular"]
        case .jsBuildOutput: ["dist", "build"]
        case .rustTarget: ["target"]
        case .pythonVenv: [".venv", "venv"]
        case .cocoaPods: ["Pods"]
        case .gradleCache: [".gradle"]
        }
    }

    public var label: String {
        switch self {
        case .nodeModules: "node_modules"
        case .jsFrameworkCache: "Framework cache"
        case .jsBuildOutput: "Build output"
        case .rustTarget: "Rust target"
        case .pythonVenv: "Python venv"
        case .cocoaPods: "CocoaPods"
        case .gradleCache: "Gradle cache"
        }
    }

    /// How the folder comes back — shown in the UI and the confirm.
    public var regenerate: String {
        switch self {
        case .nodeModules: "npm / pnpm / yarn install"
        case .jsFrameworkCache: "the next dev or build run"
        case .jsBuildOutput: "the next build"
        case .rustTarget: "cargo build"
        case .pythonVenv: "python -m venv + pip install"
        case .cocoaPods: "pod install"
        case .gradleCache: "the next Gradle build"
        }
    }

    /// Roughly how long getting it back takes — shown on every row.
    public var rebuildCost: String {
        switch self {
        case .nodeModules: "~1 min to reinstall"
        case .jsFrameworkCache: "rebuilds instantly"
        case .jsBuildOutput: "rebuilt on next build"
        case .rustTarget: "5–10 min to recompile"
        case .pythonVenv: "~1 min to reinstall"
        case .cocoaPods: "~1 min to reinstall"
        case .gradleCache: "rebuilt on next build"
        }
    }

    public static func kind(forFolderName name: String) -> JunkKind? {
        allCases.first { $0.folderNames.contains(name) }
    }

    static var allFolderNames: [String] { allCases.flatMap(\.folderNames) }

    /// The proof that `dir` really is this kind. `dir` is the junk folder; its
    /// parent is the project.
    func matches(_ dir: URL) -> Bool {
        let fm = FileManager.default
        let project = dir.deletingLastPathComponent()
        let has = { (name: String) in fm.fileExists(atPath: project.appendingPathComponent(name).path) }
        switch self {
        case .nodeModules:
            return true
        case .jsFrameworkCache:
            return has("package.json")
        case .jsBuildOutput:
            // `dist`/`build` are only junk when the project itself says so:
            // a JS project that gitignores that exact folder.
            return has("package.json") && Self.gitignore(at: project, lists: dir.lastPathComponent)
        case .rustTarget:
            return has("Cargo.toml")
        case .pythonVenv:
            return fm.fileExists(atPath: dir.appendingPathComponent("pyvenv.cfg").path)
        case .cocoaPods:
            return has("Podfile")
        case .gradleCache:
            return ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "gradlew"].contains(where: has)
        }
    }

    /// Python projects that list their packages — the only venvs that can be rebuilt.
    static let pythonManifests = [
        "requirements.txt", "requirements-dev.txt", "requirements", "pyproject.toml", "Pipfile", "Pipfile.lock",
        "poetry.lock", "uv.lock", "setup.py", "setup.cfg", "environment.yml", "environment.yaml",
    ]

    static func hasPythonManifest(_ project: URL) -> Bool {
        let fm = FileManager.default
        if pythonManifests.contains(where: { fm.fileExists(atPath: project.appendingPathComponent($0).path) }) { return true }
        // requirements/base.txt, requirements-prod.txt …
        return ((try? fm.contentsOfDirectory(atPath: project.path)) ?? [])
            .contains { $0.hasPrefix("requirements") && $0.hasSuffix(".txt") }
    }

    static let jsLockfiles = ["package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock"]

    /// A lockfile in the project or any folder up to (and including) its group
    /// root — workspaces keep one lockfile at the top.
    static func hasJSLockfile(_ project: URL, upTo root: URL) -> Bool {
        let fm = FileManager.default
        var dir = project.standardizedFileURL
        let stop = root.standardizedFileURL.path
        for _ in 0..<8 {
            if jsLockfiles.contains(where: { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) { return true }
            if dir.path == stop || dir.path.count <= stop.count { break }
            dir = dir.deletingLastPathComponent()
        }
        return false
    }

    /// Does `<project>/.gitignore` ignore `name` (as `name`, `/name`, `name/` or `/name/`)?
    static func gitignore(at project: URL, lists name: String) -> Bool {
        guard let raw = try? String(contentsOf: project.appendingPathComponent(".gitignore"), encoding: .utf8) else {
            return false
        }
        return raw.split(whereSeparator: \.isNewline).contains { line in
            var entry = line.trimmingCharacters(in: .whitespaces)
            guard !entry.hasPrefix("#"), !entry.hasPrefix("!") else { return false }
            if entry.hasPrefix("/") { entry.removeFirst() }
            if entry.hasSuffix("/") { entry.removeLast() }
            return entry == name
        }
    }
}
