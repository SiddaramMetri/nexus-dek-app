import Testing
@testable import NexusCore

@Suite struct TerminalCommandTests {
    let prefix = "/opt/homebrew"

    @Test func knownClientWhenInstalled() throws {
        let c = try TerminalCommand.resolve(formula: "postgresql@18", kind: .cli, brewPrefix: prefix, fileExists: { _ in true })
        #expect(c.program == "/opt/homebrew/bin/psql")
        #expect(c.args == ["-d", "postgres"])
    }

    @Test func fallsBackToLoginShell() throws {
        let c = try TerminalCommand.resolve(formula: "redis", kind: .cli, brewPrefix: prefix, fileExists: { _ in false }, shell: "/bin/zsh")
        #expect(c.program == "/bin/zsh")
        #expect(c.args == ["-l"])
    }

    @Test func logsReadPlistThenFallBack() throws {
        let plist = "<key>StandardOutPath</key><string>/opt/homebrew/var/log/redis.log</string>"
        let a = try TerminalCommand.resolve(formula: "redis", kind: .logs, brewPrefix: prefix, readFile: { _ in plist })
        #expect(a.args == ["-f", "/opt/homebrew/var/log/redis.log"])
        let b = try TerminalCommand.resolve(formula: "mongodb/brew/mongodb-community@7.0", kind: .logs, brewPrefix: prefix, readFile: { _ in nil })
        #expect(b.args == ["-f", "/opt/homebrew/var/log/mongodb-community.log"])
    }

    @Test func rejectsBadFormula() {
        #expect(throws: AppError.self) { try TerminalCommand.resolve(formula: "redis; rm -rf /", kind: .cli, brewPrefix: prefix) }
    }
}
