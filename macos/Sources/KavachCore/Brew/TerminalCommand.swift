import Foundation

public enum TerminalKind: String, Sendable {
    case cli, logs
    /// A login shell in a project folder that runs one of its dev scripts.
    case script
}

/// Server-side allowlist: the UI passes a formula + kind, never a program.
/// Resolves the service's client binary (or a login shell), or `tail -f` on its log.
public enum TerminalCommand {
    public static func resolve(
        formula: String, kind: TerminalKind, brewPrefix: String,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) },
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    ) throws -> (program: String, args: [String]) {
        try Validate.formula(formula)
        // brew installs a tap formula under its bare name (opt/mongodb-community@7.0).
        let formula = bareFormula(formula)
        let base = formula.split(separator: "@").first.map(String.init) ?? formula
        let bin = { (name: String) in "\(brewPrefix)/bin/\(name)" }

        if kind == .logs {
            let plist = "\(brewPrefix)/opt/\(formula)/homebrew.mxcl.\(formula).plist"
            let log = readFile(plist).flatMap { Parsers.logPath(fromPlist: $0) } ?? "\(brewPrefix)/var/log/\(base).log"
            return ("/usr/bin/tail", ["-f", log])
        }

        let client: (String, [String])? = switch base {
        case "redis", "valkey": (bin("redis-cli"), [])
        // psql defaults to a DB named after the OS user, which usually doesn't exist.
        case "postgresql", "postgres": (bin("psql"), ["-d", "postgres"])
        case "mysql", "mariadb", "percona-server": (bin("mysql"), [])
        case "mongodb", "mongodb-community": (bin("mongosh"), [])
        default: nil
        }
        if let client, fileExists(client.0) { return client }
        return (shell, ["-l"])
    }
}
