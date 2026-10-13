import Foundation

/// What a dev server is for — drives the badge and the order on a card.
public enum ServerRole: String, Sendable, Comparable {
    case frontend, backend, database, tool

    var rank: Int {
        switch self {
        case .frontend: 0
        case .backend: 1
        case .database: 2
        case .tool: 3
        }
    }

    public static func < (a: ServerRole, b: ServerRole) -> Bool { a.rank < b.rank }

    public var label: String {
        switch self {
        case .frontend: "Frontend"
        case .backend: "Backend"
        case .database: "Database"
        case .tool: "Tool"
        }
    }
}

/// A dev server a project declares (a package.json script or Django's
/// manage.py), whether or not it's running right now.
public struct DeclaredServer: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { "\(dir)|\(script)" }
    /// Folder the script runs in (where its package.json / manage.py lives).
    public let dir: String
    /// Script name for `<pm> run <script>`; for Django, "runserver".
    public let script: String
    /// The actual command, e.g. `next dev --port 3000`.
    public let command: String
    public let framework: String?
    public let role: ServerRole
    /// Explicit `--port`/`PORT=` or the framework's default; nil when unknown.
    public let port: Int?
    /// pnpm / npm / yarn / bun — or "python" for Django.
    public let runner: String
    /// Script file it runs (`agent/index.js`), used to recognise it when running.
    public let entry: String?
    /// Starts the whole project (`./run.sh --dev`, `docker compose up`, `a && b`)
    /// rather than one server — offered as "Start all", never listed as a row.
    public var isLauncher: Bool = false

    /// Absolute path of `entry`, for de-duplicating the same server declared twice.
    var entryPath: String? {
        entry.map { ((dir as NSString).appendingPathComponent($0) as NSString).standardizingPath }
    }

    /// Display name: framework, else the entry script, else the script name.
    public var name: String { framework ?? entry ?? script }

    /// What the user would type, shown under the name ("pnpm dev:next").
    public var launchLabel: String {
        runner == "python" ? "python manage.py runserver" : "\(runner) \(runner == "npm" ? "run " : "")\(script)"
    }
}

/// Reads a project's declared dev servers from its files. Read-only, no
/// subprocesses: package.json files at the root and up to two levels down
/// (`frontend/`, `apps/web/`), plus Django `manage.py`.
public enum ProjectServers {
    static let maxPackages = 24
    static let skipDirs: Set<String> = ["node_modules", "dist", "build", "target", "vendor", "Pods", "venv", ".venv"]

    public static func discover(root: String) -> [DeclaredServer] {
        var out: [DeclaredServer] = []
        for dir in candidateDirs(root) {
            out += fromPackageJSON(dir: dir)
            if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("manage.py")) {
                out.append(DeclaredServer(dir: dir, script: "runserver", command: "python manage.py runserver",
                                          framework: "Django", role: .backend, port: 8000, runner: "python", entry: nil))
            }
        }
        // One server per id, and per real script file: `agent/package.json`'s
        // `node index.js` is the root's `node agent/index.js`.
        var seen = Set<String>(), seenEntries = Set<String>()
        return out.filter { s in
            guard seen.insert(s.id).inserted else { return false }
            if let e = s.entryPath { return seenEntries.insert(e).inserted }
            return true
        }
        .sorted { ($0.role, $0.port ?? .max, $0.dir) < ($1.role, $1.port ?? .max, $1.dir) }
    }

    /// The root plus folders one and two levels down (skipping junk and dot dirs).
    static func candidateDirs(_ root: String) -> [String] {
        let fm = FileManager.default
        func children(_ d: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: d)) ?? [])
                .filter { !$0.hasPrefix(".") && !skipDirs.contains($0) }
                .map { (d as NSString).appendingPathComponent($0) }
                .filter { var isDir: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue }
                .sorted()
        }
        var dirs = [root]
        for c in children(root) {
            dirs.append(c)
            dirs += children(c)
        }
        let hasManifest = { (d: String) in
            ["package.json", "manage.py"].contains { fm.fileExists(atPath: (d as NSString).appendingPathComponent($0)) }
        }
        return Array(dirs.filter(hasManifest).prefix(maxPackages))
    }

    // MARK: - package.json

    static func fromPackageJSON(dir: String) -> [DeclaredServer] {
        let url = URL(fileURLWithPath: dir).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let scripts = obj["scripts"] as? [String: String] else { return [] }
        return servers(scripts: scripts, dir: dir, runner: packageManager(dir))
    }

    /// Script names that start a dev server.
    static func isServerScript(_ name: String) -> Bool {
        name == "dev" || name.hasPrefix("dev:") || name == "serve" || name == "start" || name.hasPrefix("start:")
    }

    /// Unique server commands from the scripts. `concurrently`/`run-p` scripts
    /// are split into their parts, and each part is credited to the script that
    /// runs it alone (`dev:next`, `agent`) when one exists, so Start runs just
    /// that server. Production `start`/`serve` are skipped when a `dev` exists.
    static func servers(scripts: [String: String], dir: String, runner: String) -> [DeclaredServer] {
        let hasDev = scripts.keys.contains { $0 == "dev" || $0.hasPrefix("dev:") }
        // Single-command scripts, by what they run (dev-named first on ties).
        var dedicated: [String: String] = [:]
        for name in scripts.keys.sorted(by: { ($0.hasPrefix("dev") ? 0 : 1, $0) < ($1.hasPrefix("dev") ? 0 : 1, $1) }) {
            guard let body = scripts[name], split(body).count == 1 else { continue }
            let key = normalize(body)
            if dedicated[key] == nil { dedicated[key] = name }
        }
        var found: [(script: String, command: String)] = []
        var seen = Set<String>()
        for name in scripts.keys.sorted() where isServerScript(name) {
            if hasDev, name == "start" || name.hasPrefix("start:") || name == "serve" { continue }
            for part in split(scripts[name] ?? "") {
                var command = part
                // `pnpm dev:next` / `npm run agent` inside a combined script → that script's command.
                if let ref = referencedScript(part), let body = scripts[ref], split(body).count == 1 { command = body }
                let key = normalize(command)
                guard !isBuildOnly(command), seen.insert(key).inserted else { continue }
                found.append((dedicated[key] ?? name, command))
            }
        }
        return found.map { script, command in
            let framework = PortFramework.detect(commandLine: command)
            let generic = framework.map { $0.hasPrefix("Node.js") || $0.hasPrefix("Bun") || $0.hasPrefix("Deno") } ?? true
            var s = DeclaredServer(
                dir: dir, script: script, command: command, framework: generic ? nil : framework,
                role: role(framework: generic ? nil : framework, dir: dir), port: port(in: command, framework: framework),
                runner: runner, entry: entry(in: command))
            s.isLauncher = isLauncher(command)
            return s
        }
    }

    /// Splits `concurrently "a" "b"` / `run-p a b` / `a & b` into commands.
    static func split(_ body: String) -> [String] {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("concurrently ") || trimmed.contains(" concurrently ") {
            let quoted = quotedParts(trimmed)
            if !quoted.isEmpty { return quoted }
        }
        if trimmed.hasPrefix("run-p ") || trimmed.hasPrefix("npm-run-all ") {
            return trimmed.split(separator: " ").dropFirst().filter { !$0.hasPrefix("-") }.map { "npm run \($0)" }
        }
        return trimmed.components(separatedBy: " & ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func quotedParts(_ s: String) -> [String] {
        var parts: [String] = [], current = "", quote: Character?
        for ch in s {
            if let q = quote {
                if ch == q { parts.append(current); current = ""; quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            }
        }
        return parts.map { $0.replacingOccurrences(of: "\\\"", with: "\"").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `pnpm dev:next`, `npm run agent`, `yarn api` → the script name.
    static func referencedScript(_ command: String) -> String? {
        let t = command.split(separator: " ").map(String.init)
        guard let first = t.first, ["npm", "pnpm", "yarn", "bun"].contains(first), t.count >= 2 else { return nil }
        if t[1] == "run" || t[1] == "run-script" { return t.count >= 3 ? t[2] : nil }
        return first == "npm" ? nil : t[1]
    }

    static func normalize(_ c: String) -> String {
        c.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whole-project start scripts: a shell script, compose, make, turbo, or a
    /// chain of steps (`pnpm install && ./run.sh --dev`).
    static func isLauncher(_ command: String) -> Bool {
        let c = command.lowercased()
        let t = c.split(whereSeparator: \.isWhitespace).map(String.init)
        return c.contains("&&") || t.contains { $0.hasSuffix(".sh") }
            || c.contains("docker compose") || c.contains("docker-compose") || t.first == "make"
            || (t.first == "turbo" || t.contains("turbo")) && t.contains("dev") || t.first == "nx"
    }

    /// `tsc --watch`, `tailwindcss -w`, lint and tests aren't servers.
    static func isBuildOnly(_ command: String) -> Bool {
        let first = command.split(separator: " ").first.map { String($0).lowercased() } ?? ""
        return ["tsc", "tailwindcss", "eslint", "jest", "vitest", "prisma", "rimraf", "echo", "cp", "mkdir"].contains(first)
            || command.contains(" build") && !command.contains("watch") && !command.contains("dev")
    }

    static func packageManager(_ dir: String) -> String {
        let fm = FileManager.default
        var d = URL(fileURLWithPath: dir)
        for _ in 0..<4 {
            let has = { (f: String) in fm.fileExists(atPath: d.appendingPathComponent(f).path) }
            if has("pnpm-lock.yaml") || has("pnpm-workspace.yaml") { return "pnpm" }
            if has("yarn.lock") { return "yarn" }
            if has("bun.lockb") || has("bun.lock") { return "bun" }
            if has("package-lock.json") { return "npm" }
            d = d.deletingLastPathComponent()
        }
        return "npm"
    }

    // MARK: - Role, port, entry

    static let frontendFrameworks: Set<String> = [
        "Next.js", "Nuxt", "Astro", "Remix", "Vite", "Angular", "webpack-dev-server", "Storybook", "Hugo",
    ]

    static func role(framework: String?, dir: String) -> ServerRole {
        if let f = framework, frontendFrameworks.contains(f) { return .frontend }
        let name = (dir as NSString).lastPathComponent.lowercased()
        if ["frontend", "web", "client", "ui", "site", "www", "app", "dashboard", "admin"].contains(name), framework == nil {
            return .frontend
        }
        if framework == "Storybook" { return .tool }
        return .backend
    }

    static let defaultPorts: [String: Int] = [
        "Next.js": 3000, "Nuxt": 3000, "Remix": 3000, "NestJS": 3000, "Rails": 3000, "Vite": 5173,
        "Astro": 4321, "Angular": 4200, "Storybook": 6006, "Django": 8000, "FastAPI": 8000, "Flask": 5000,
        "Hugo": 1313, "Jupyter": 8888,
    ]

    /// `--port 3000`, `--port=3000`, `-p 3000`, `PORT=3000 …`, else the framework default.
    static func port(in command: String, framework: String?) -> Int? {
        let t = command.split(whereSeparator: \.isWhitespace).map(String.init)
        for (i, tok) in t.enumerated() {
            if tok.hasPrefix("--port="), let p = Int(tok.dropFirst(7)) { return p }
            if tok.hasPrefix("PORT="), let p = Int(tok.dropFirst(5)) { return p }
            if (tok == "--port" || tok == "-p"), i + 1 < t.count, let p = Int(t[i + 1]) { return p }
        }
        return framework.flatMap { defaultPorts[$0] }
    }

    /// First script-file argument, kept relative (`agent/index.js`).
    static func entry(in command: String) -> String? {
        let exts = [".js", ".mjs", ".cjs", ".ts", ".mts", ".py"]
        return command.split(whereSeparator: \.isWhitespace).dropFirst().map(String.init)
            .first { t in !t.hasPrefix("-") && exts.contains { t.lowercased().hasSuffix($0) } }
    }

    // MARK: - Matching running processes

    /// Does this running port belong to that declared server? By script file
    /// (`…/docklyt/agent/index.js` in the command line), then by port.
    public static func matches(_ p: PortInfo, _ s: DeclaredServer) -> Bool {
        if let entry = s.entry, let cl = p.commandLine {
            let full = ((s.dir as NSString).appendingPathComponent(entry) as NSString).standardizingPath
            if cl.contains(full) { return true }
            if p.cwd.map({ ($0 as NSString).standardizingPath == (s.dir as NSString).standardizingPath }) == true,
               cl.split(separator: " ").contains(where: { $0 == entry }) { return true }
        }
        if let port = s.port, port == p.port {
            return true
        }
        return false
    }
}

/// Launch command for a declared server — fixed runners only, script names
/// validated, so nothing user-controlled can become shell syntax.
public enum ScriptLaunch {
    public static func command(for s: DeclaredServer) throws -> String {
        if s.runner == "python" { return "python3 manage.py runserver" }
        guard ["pnpm", "npm", "yarn", "bun"].contains(s.runner) else { throw AppError.invalidName("unknown runner") }
        guard s.script.range(of: #"^[A-Za-z0-9][A-Za-z0-9:._-]{0,63}$"#, options: .regularExpression) != nil else {
            throw AppError.invalidName("invalid script name: \(s.script)")
        }
        return s.runner == "npm" || s.runner == "bun" ? "\(s.runner) run \(s.script)" : "\(s.runner) \(s.script)"
    }
}
