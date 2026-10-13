import Foundation
import Testing
@testable import NexusCore

/// Real `--version` output, captured read-only from a dev Mac.
enum ToolFixtures {
    static let versions: [(output: String, expected: String)] = [
        ("2.1.296 (Claude Code)\n", "2.1.296"),
        ("codex-cli 0.162.1\n", "0.162.1"),
        ("gh version 2.96.0 (2026-07-02)\nhttps://github.com/cli/cli/releases/tag/v2.96.0\n", "2.96.0"),
        ("git version 2.54.0 (Apple Git-157)\n", "2.54.0"),
        ("v20.14.0\n", "20.14.0"),
        ("10.7.0\n", "10.7.0"),
        ("Python 3.14.4\n", "3.14.4"),
        ("uv 0.9.28 (0e1351e40 2026-01-29)\n", "0.9.28"),
        ("rustc 1.95.0 (59807616e 2026-04-14)\n", "1.95.0"),
        ("cargo 1.95.0 (f2d3ce0bd 2026-03-21)\n", "1.95.0"),
        ("rustup 1.29.0 (28d1352db 2026-03-05)\n", "1.29.0"),
        ("go version go1.27.1 darwin/arm64\n", "1.27.1"),
        ("Docker version 28.3.3, build 980b856816\n", "28.3.3"),
        ("colima version 0.8.4\n", "0.8.4"),
        ("podman version 5.6.1\n", "5.6.1"),
        ("Terraform v1.15.3\non darwin_arm64\n", "1.15.3"),
        ("aws-cli/2.34.4 Python/3.13.12 Darwin/27.0.0 source/arm64\n", "2.34.4"),
        ("Homebrew 7.0.9\n", "7.0.9"),
        ("1.3.11\n", "1.3.11"),
        ("""
         openjdk version "17.0.16" 2025-07-15
         OpenJDK Runtime Environment Homebrew (build 17.0.16+0)
         """, "17.0.16"),
        ("openjdk version \"21\" 2023-09-19\n", "21"),
        ("Client Version: v1.31.0\nKustomize Version: v5.4.2\n", "1.31.0"),
        ("2.1.0-beta.3\n", "2.1.0-beta.3"),
    ]

    static let rustupOutdated = """
    stable-aarch64-apple-darwin - update available: 1.95.0 (59807616e 2026-04-14) -> 1.99.0 (b940084d7 2026-09-28)
    rustup - update available : 1.29.0 -> 1.29.1
    """
    static let rustupCurrent = """
    stable-aarch64-apple-darwin - Up to date : 1.95.0 (59807616e 2026-04-14)
    rustup - Up to date : 1.29.0
    """

    static func tool(_ id: String, _ method: InstallMethod, version: String? = "1.0.0",
                     path: String = "/x", resolved: String? = nil) -> DevTool {
        DevTool(id: id, name: id, kind: method == .app ? .app : .cli, symbol: "app", version: version,
                path: path, resolvedPath: resolved ?? path, method: method)
    }
}

@Suite struct ToolVersionTests {
    @Test func parsesRealVersionOutputs() {
        for (output, expected) in ToolFixtures.versions {
            #expect(ToolVersion.parse(output) == expected, "\(output)")
        }
        #expect(ToolVersion.parse("") == nil)
        #expect(ToolVersion.parse("command not found") == nil)
    }

    @Test func comparesNumerically() {
        #expect(ToolVersion.compare("1.10.0", "1.9.9") == 1)
        #expect(ToolVersion.compare("2.1.296", "2.1.300") == -1)
        #expect(ToolVersion.compare("1.2", "1.2.0") == 0)
        #expect(ToolVersion.compare("garbage", "1.0") == nil)
    }

    @Test func handlesPrefixesAndSuffixes() {
        #expect(ToolVersion.compare("v22.18.0", "22.18.0") == 0)
        #expect(ToolVersion.compare("V1.0.0", "v1.0.1") == -1)
        // brew revision and cask build suffixes are not part of the version
        #expect(ToolVersion.compare("3.14.4", "3.14.4_1") == 0)
        #expect(ToolVersion.compare("1.141.0,abc123", "1.141.0") == 0)
        #expect(ToolVersion.compare("1.0.0+build.5", "1.0.0") == 0)
    }

    @Test func prereleaseSortsBeforeRelease() {
        #expect(ToolVersion.compare("2.0.0-rc.1", "2.0.0") == -1)
        #expect(ToolVersion.compare("2.0.0", "2.0.0-rc.1") == 1)
        #expect(ToolVersion.compare("2.0.0-alpha", "2.0.0-beta") == -1)
        #expect(ToolVersion.compare("2.0.0-rc.2", "2.0.0-rc.10") == -1)
        #expect(ToolVersion.compare("2.0.0-rc.1", "2.0.0-rc") == 1)
        #expect(ToolVersion.compare("2.0.0-1", "2.0.0-alpha") == -1)
    }

    @Test func sortsAndReadsMajor() {
        #expect(ToolVersion.sortedDescending(["v18.20.8", "v22.18.0", "v20.19.4"]) == ["v22.18.0", "v20.19.4", "v18.20.8"])
        #expect(ToolVersion.major("v22.18.0") == 22)
        #expect(ToolVersion.major("x") == nil)
        #expect(ToolVersion.display("3.14.8_2") == "3.14.8")
        #expect(ToolVersion.display("2.0.0-rc.1") == "2.0.0-rc.1")
    }
}

@Suite struct ToolInstallMethodTests {
    let home = "/Users/me"

    private func detect(_ id: String, _ link: String, _ resolved: String) -> InstallMethod {
        InstallMethod.detect(toolID: id, link: link, resolved: resolved, home: home)
    }

    @Test func homebrewFormulaAndCask() {
        #expect(detect("python3", "/opt/homebrew/bin/python3",
                       "/opt/homebrew/Cellar/python@3.14/3.14.4_1/Frameworks/Python.framework/Versions/3.14/bin/python3.14")
            == .brewFormula("python@3.14"))
        #expect(detect("aws", "/opt/homebrew/bin/aws", "/opt/homebrew/Cellar/awscli/2.34.4_1/libexec/bin/aws")
            == .brewFormula("awscli"))
        #expect(detect("java", "/usr/bin/java", "/opt/homebrew/Cellar/openjdk@17/17.0.16/libexec/openjdk.jdk/Contents/Home")
            == .brewFormula("openjdk@17"))
        #expect(detect("codex", "/opt/homebrew/bin/codex", "/opt/homebrew/Caskroom/codex/0.160.0/codex-aarch64-apple-darwin")
            == .brewCask("codex"))
        #expect(detect("brew", "/opt/homebrew/bin/brew", "/opt/homebrew/bin/brew") == .homebrewSelf)
    }

    @Test func npmGlobals() {
        #expect(detect("claude", "\(home)/.npm-global/bin/claude",
                       "\(home)/.npm-global/lib/node_modules/@anthropic-ai/claude-code/cli.js")
            == .npmGlobal(package: "@anthropic-ai/claude-code", nvm: false))
        #expect(detect("gemini", "\(home)/.nvm/versions/node/v22.18.0/bin/gemini",
                       "\(home)/.nvm/versions/node/v22.18.0/lib/node_modules/@google/gemini-cli/dist/index.js")
            == .npmGlobal(package: "@google/gemini-cli", nvm: true))
        #expect(detect("pnpm", "/usr/local/bin/pnpm", "/usr/local/lib/node_modules/pnpm/bin/pnpm.cjs")
            == .npmGlobal(package: "pnpm", nvm: false))
        #expect(detect("node", "\(home)/.nvm/versions/node/v22.18.0/bin/node",
                       "\(home)/.nvm/versions/node/v22.18.0/bin/node") == .nvm)
    }

    @Test func nativeInstallers() {
        #expect(detect("claude", "\(home)/.local/bin/claude", "\(home)/.local/share/claude/versions/2.1.296") == .claudeNative)
        #expect(detect("codex", "\(home)/.local/bin/codex",
                       "\(home)/.codex/packages/standalone/releases/0.162.1-aarch64-apple-darwin/bin/codex")
            == .codexStandalone)
        #expect(detect("rust", "\(home)/.cargo/bin/rustc", "\(home)/.cargo/bin/rustup") == .rustup)
        #expect(detect("uv", "\(home)/.local/bin/uv", "\(home)/.local/bin/uv") == .uvStandalone)
        #expect(detect("bun", "\(home)/.bun/bin/bun", "\(home)/.bun/bin/bun") == .bunInstaller)
        #expect(detect("deno", "\(home)/.deno/bin/deno", "\(home)/.deno/bin/deno") == .denoInstaller)
    }

    @Test func systemAndBundled() {
        #expect(detect("git", "/usr/bin/git", "/usr/bin/git") == .commandLineTools)
        #expect(detect("node", "/usr/local/bin/node", "/usr/local/bin/node") == .installerPackage)
        #expect(detect("docker", "/usr/local/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker")
            == .bundled(app: "Docker"))
        #expect(detect("go", "/somewhere/go/bin/go", "/somewhere/go/bin/go") == .manual)
    }

    @Test func nvmAliasResolution() {
        let versions = ["v22.18.0", "v20.19.4", "v18.20.8"]
        #expect(ToolLocator.matchNvmVersion("v20.19.4", versions) == "v20.19.4")
        #expect(ToolLocator.matchNvmVersion("20", versions) == "v20.19.4")
        #expect(ToolLocator.matchNvmVersion("node", versions) == "v22.18.0")
        #expect(ToolLocator.matchNvmVersion("lts/*", versions) == nil)
        #expect(ToolLocator.matchNvmVersion("2", versions) == nil)
    }
}

@Suite struct ToolUpdateCommandTests {
    typealias F = ToolFixtures

    @Test func fixedTablePerMethod() throws {
        #expect(try ToolUpdate.command(for: F.tool("gh", .brewFormula("gh"))) == "brew upgrade gh")
        #expect(try ToolUpdate.command(for: F.tool("cursor", .brewCask("cursor"))) == "brew upgrade --cask cursor")
        #expect(try ToolUpdate.command(for: F.tool("gemini", .npmGlobal(package: "@google/gemini-cli", nvm: true)))
            == "npm install -g @google/gemini-cli@latest")
        #expect(try ToolUpdate.command(for: F.tool("claude", .claudeNative)) == "claude update")
        #expect(try ToolUpdate.command(for: F.tool("codex", .codexStandalone)) == "codex update")
        #expect(try ToolUpdate.command(for: F.tool("rust", .rustup)) == "rustup update")
        #expect(try ToolUpdate.command(for: F.tool("uv", .uvStandalone)) == "uv self update")
        #expect(try ToolUpdate.command(for: F.tool("brew", .homebrewSelf)) == "brew update")
        #expect(try ToolUpdate.command(for: F.tool("node", .nvm, version: "22.18.0"))
            == "nvm install 22 --reinstall-packages-from=current")
    }

    @Test func noCommandForSelfManaged() throws {
        #expect(try ToolUpdate.command(for: F.tool("vscode", .app)) == nil)
        #expect(try ToolUpdate.command(for: F.tool("git", .commandLineTools)) == nil)
        #expect(try ToolUpdate.command(for: F.tool("docker", .bundled(app: "Docker"))) == nil)
        #expect(try ToolUpdate.command(for: F.tool("node", .installerPackage)) == nil)
        #expect(try ToolUpdate.command(for: F.tool("node", .nvm, version: nil)) == nil)
    }

    @Test func rejectsUnsafeNames() {
        #expect(throws: AppError.self) { try ToolUpdate.command(for: F.tool("x", .brewFormula("gh; rm -rf ~"))) }
        #expect(throws: AppError.self) { try ToolUpdate.command(for: F.tool("x", .brewCask("--force"))) }
        #expect(throws: AppError.self) {
            try ToolUpdate.command(for: F.tool("x", .npmGlobal(package: "pkg && curl evil", nvm: false)))
        }
        #expect(throws: AppError.self) { try ToolUpdate.command(for: F.tool("x", .npmGlobal(package: "$(id)", nvm: false))) }
    }

    @Test func npmNames() {
        #expect(NpmName.isValid("@anthropic-ai/claude-code"))
        #expect(NpmName.isValid("pnpm"))
        #expect(NpmName.isValid("lodash.merge"))
        #expect(!NpmName.isValid("Uppercase"))
        #expect(!NpmName.isValid("-flag"))
        #expect(!NpmName.isValid("@scope/"))
        #expect(!NpmName.isValid("a b"))
        #expect(!NpmName.isValid("a/b/c"))
        #expect(!NpmName.isValid(String(repeating: "a", count: 215)))
    }

    @Test func batchesBrewIntoOneCommand() throws {
        let tools = [
            F.tool("gh", .brewFormula("gh")), F.tool("go", .brewFormula("go")),
            F.tool("cursor", .brewCask("cursor")), F.tool("claude", .claudeNative),
            F.tool("vscode", .app), F.tool("terraform", .brewFormula("terraform")),
        ]
        #expect(try ToolUpdate.batch(tools)
            == "brew upgrade gh go terraform; brew upgrade --cask cursor; claude update")
        #expect(try ToolUpdate.batch([F.tool("vscode", .app)]) == nil)
        #expect(throws: AppError.self) { try ToolUpdate.batch([F.tool("x", .brewFormula("a;b"))]) }
    }
}

@Suite struct ToolLatestTests {
    typealias F = ToolFixtures

    @Test func sourcePerMethod() {
        #expect(LatestSource.of(F.tool("gh", .brewFormula("gh"))) == .brew)
        #expect(LatestSource.of(F.tool("claude", .claudeNative)) == .npm("@anthropic-ai/claude-code"))
        #expect(LatestSource.of(F.tool("codex", .codexStandalone)) == .npm("@openai/codex"))
        #expect(LatestSource.of(F.tool("node", .nvm, version: "22.18.0")) == .nodeDist(major: 22))
        #expect(LatestSource.of(F.tool("node", .installerPackage, version: "20.14.0")) == .nodeDist(major: 20))
        #expect(LatestSource.of(F.tool("aws", .installerPackage)) == .none)
        #expect(LatestSource.of(F.tool("rust", .rustup)) == .rustup)
        #expect(LatestSource.of(F.tool("vscode", .app)) == .note("Updates itself"))
        #expect(LatestSource.of(F.tool("git", .commandLineTools)) == .note("Via Software Update"))
    }

    @Test func parsesRustupCheck() {
        #expect(ToolLatestChecker.parseRustupCheck(F.rustupOutdated) == "1.99.0")
        #expect(ToolLatestChecker.parseRustupCheck(F.rustupCurrent) == "1.95.0")
        #expect(ToolLatestChecker.parseRustupCheck("error: no network") == nil)
    }

    @Test func parsesBrewOutdated() throws {
        let map = try #require(ToolLatestChecker.parseBrewOutdated(fixture("brew-outdated.json")))
        #expect(map["assimp"] == "6.0.5")
        #expect(map["zulu@11"] != nil)
        #expect(ToolLatestChecker.parseBrewOutdated(#"{"formulae":[],"casks":[]}"#)?.isEmpty == true)
        // A failed run must not read as "everything up to date".
        #expect(ToolLatestChecker.parseBrewOutdated("") == nil)
        #expect(ToolLatestChecker.parseBrewOutdated("{}") == nil)
    }

    @Test func parsesRegistryResponses() {
        #expect(ToolLatestChecker.parseNpmView("2.1.300\n") == "2.1.300")
        #expect(ToolLatestChecker.parseNpmView("\"0.163.0\"\n") == "0.163.0")
        #expect(ToolLatestChecker.parseNpmView("npm error 404\n") == nil)
        #expect(ToolLatestChecker.parseNpmLatest(Data(#"{"name":"bun","version":"1.3.12"}"#.utf8)) == "1.3.12")
        let dist = #"[{"version":"v24.1.0"},{"version":"v22.20.0"},{"version":"v22.19.0"},{"version":"v20.19.5"}]"#
        #expect(ToolLatestChecker.parseNodeDist(Data(dist.utf8), major: 22) == "22.20.0")
        #expect(ToolLatestChecker.parseNodeDist(Data(dist.utf8), major: 18) == nil)
        #expect(ToolLatestChecker.parsePyPI(Data(#"{"info":{"version":"0.9.30"}}"#.utf8)) == "0.9.30")
        #expect(ToolLatestChecker.parseGitHubRelease(Data(#"{"tag_name":"v2.1.4"}"#.utf8)) == "2.1.4")
        #expect(ToolLatestChecker.parseGitHubRelease(Data(#"{"tag_name":"7.0.10"}"#.utf8)) == "7.0.10")
    }

    @Test func statusFromRecord() {
        #expect(ToolStatus.resolve(installed: "1.0.0", record: nil) == .unchecked)
        #expect(ToolStatus.resolve(installed: "1.0.0", record: LatestRecord(latest: "1.1.0")) == .updateAvailable("1.1.0"))
        #expect(ToolStatus.resolve(installed: "1.1.0", record: LatestRecord(latest: "1.1.0")) == .upToDate)
        // brew: outdated record goes stale once the user upgrades
        #expect(ToolStatus.resolve(installed: "1.16.5", record: LatestRecord(latest: "1.16.5", outdated: true)) == .upToDate)
        #expect(ToolStatus.resolve(installed: nil, record: LatestRecord(latest: "2.0", outdated: true)) == .updateAvailable("2.0"))
        #expect(ToolStatus.resolve(installed: "1.0", record: LatestRecord(outdated: false)) == .upToDate)
        #expect(ToolStatus.resolve(installed: "1.0", record: LatestRecord(note: "Updates itself")) == .managed("Updates itself"))
        #expect(ToolStatus.resolve(installed: "1.0", record: .failed()) == .couldntCheck)
    }

    @Test func dailyAutoCheck() {
        let now = Date()
        #expect(ToolsUpdateCache().isDue(now: now))
        #expect(!ToolsUpdateCache(checkedAt: now.addingTimeInterval(-3600)).isDue(now: now))
        #expect(ToolsUpdateCache(checkedAt: now.addingTimeInterval(-25 * 3600)).isDue(now: now))
    }

    @Test func filterMatches() {
        let cli = F.tool("gh", .brewFormula("gh"))
        let app = F.tool("vscode", .app)
        #expect(ToolFilter.updates.matches(cli, status: .updateAvailable("2"), query: ""))
        #expect(!ToolFilter.updates.matches(cli, status: .upToDate, query: ""))
        #expect(ToolFilter.apps.matches(app, status: .upToDate, query: ""))
        #expect(!ToolFilter.clis.matches(app, status: .upToDate, query: ""))
        #expect(ToolFilter.all.matches(cli, status: .upToDate, query: "homebrew"))
        #expect(!ToolFilter.all.matches(cli, status: .upToDate, query: "zzz"))
    }
}
