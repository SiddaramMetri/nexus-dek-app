import Foundation
import Testing
@testable import NexusCore

@Suite struct PackagesTests {
    @Test func parsesInstalledLine() {
        let one = PackagesBackend.parseInstalledLine("redis 8.8.0")
        #expect(one?.name == "redis")
        #expect(one?.version == "8.8.0")
        let multi = PackagesBackend.parseInstalledLine("openssl@3 3.5.0 3.4.1")
        #expect(multi?.name == "openssl@3")
        #expect(multi?.version == "3.5.0, 3.4.1")
        #expect(PackagesBackend.parseInstalledLine("   ") == nil)
    }

    @Test func parsesOutdatedFixture() {
        let list = PackagesBackend.parseOutdated(fixture("brew-outdated.json"))
        // assimp was outdated 5.4.3 → 6.0.5 in the captured fixture
        #expect(list.first { $0.name == "assimp" }?.latestVersion == "6.0.5")
        // casks are included too
        #expect(list.contains { $0.name == "zulu@11" })
    }

    @Test func outdatedGarbageIsEmpty() {
        #expect(PackagesBackend.parseOutdated("").isEmpty)
        #expect(PackagesBackend.parseOutdated("not json").isEmpty)
        #expect(PackagesBackend.parseOutdated("{}").isEmpty)
    }

    @Test func parsesInstalledFixtureSortedWithKinds() {
        let items = PackagesBackend.parseInstalled(
            formulae: fixture("brew-list-versions.txt"),
            casks: "zulu@11 11.0.20.1,11.66.19-ca\nalacritty 0.15.1\n")
        #expect(items.count == 185)
        #expect(items.map(\.name) == items.map(\.name).sorted())
        #expect(items.first { $0.name == "assimp" }?.version == "5.4.3")
        #expect(items.first { $0.name == "alacritty" }?.kind == .cask)
        #expect(items.allSatisfy { !$0.outdated && $0.latestVersion == nil && !$0.pinned })
    }

    @Test func tolerateOnlyPassesUntrustedTap() throws {
        #expect(try PackagesBackend.tolerate(.success("x 1")) == "x 1")
        #expect(try PackagesBackend.tolerate(.failure(AppError.shell("no casks"))) == "")
        #expect(try PackagesBackend.tolerate(.failure(AppError.busy("busy"))) == "")
        #expect(throws: AppError.untrustedTap("user/tap")) {
            try PackagesBackend.tolerate(.failure(AppError.untrustedTap("user/tap")))
        }
    }

    @Test func mergesOutdatedOntoInstalled() {
        let installed = [
            PackageItem(name: "assimp", version: "5.4.3", kind: .formula),
            PackageItem(name: "redis", version: "8.8.0", kind: .formula),
            PackageItem(name: "node", version: "22", kind: .formula),
        ]
        let outdated = [
            OutdatedInfo(name: "assimp", latestVersion: "6.0.5", pinned: false),
            OutdatedInfo(name: "node", latestVersion: "24", pinned: true),
        ]
        let merged = PackagesBackend.merge(installed, outdated: outdated)
        #expect(merged[0].outdated && merged[0].latestVersion == "6.0.5")
        #expect(!merged[1].outdated)
        #expect(merged[2].pinned)
        #expect(PackagesBackend.upgradeableCount(merged) == 1)
        #expect(PackagesBackend.merge(installed, outdated: nil) == installed)
    }

    @Test func filtersByKindOutdatedAndQuery() {
        let items = [
            PackageItem(name: "redis", version: "8", kind: .formula, outdated: true),
            PackageItem(name: "Docker", version: "4", kind: .cask),
            PackageItem(name: "postgresql@18", version: "18", kind: .formula),
        ]
        #expect(PackagesBackend.filter(items, query: "", filter: .all).count == 3)
        #expect(PackagesBackend.filter(items, query: "", filter: .formula).count == 2)
        #expect(PackagesBackend.filter(items, query: "", filter: .cask).map(\.name) == ["Docker"])
        #expect(PackagesBackend.filter(items, query: "", filter: .outdated).map(\.name) == ["redis"])
        #expect(PackagesBackend.filter(items, query: " DOCK ", filter: .all).map(\.name) == ["Docker"])
        #expect(PackagesBackend.filter(items, query: "redis", filter: .cask).isEmpty)
    }

    @Test func parsesFormulaInfo() throws {
        let json = """
        {"formulae":[{"name":"redis","desc":"Persistent key-value database","homepage":"https://redis.io/",
        "versions":{"stable":"8.8.0"},"dependencies":["openssl@3"],"service":{"run":["redis-server"]}}],"casks":[]}
        """
        let info = try PackagesBackend.parseInfo(json, name: "redis")
        #expect(info == PackageDetails(name: "redis", description: "Persistent key-value database",
                                       homepage: "https://redis.io/", version: "8.8.0",
                                       dependencies: ["openssl@3"], isService: true, isCask: false))
    }

    @Test func parsesCaskInfoAndNullService() throws {
        let json = """
        {"formulae":[],"casks":[{"token":"alacritty","desc":null,"homepage":"https://alacritty.org/","version":"0.15.1","service":null}]}
        """
        let info = try PackagesBackend.parseInfo(json, name: "alacritty")
        #expect(info.isCask)
        #expect(!info.isService)
        #expect(info.description == nil)
        #expect(info.version == nil)
        #expect(info.dependencies.isEmpty)
    }

    @Test func infoErrors() {
        #expect(throws: AppError.notFound("no info for x")) {
            try PackagesBackend.parseInfo(#"{"formulae":[],"casks":[]}"#, name: "x")
        }
        #expect(throws: AppError.self) { try PackagesBackend.parseInfo("nope", name: "x") }
    }
}
