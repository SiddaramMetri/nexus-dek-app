import Foundation
import Testing
@testable import NexusCore

func fixture(_ name: String) -> String {
    // Read from source (no bundled resources — keeps `swift test` working under the CLT toolchain).
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    return try! String(contentsOf: url, encoding: .utf8)
}

@Suite struct ParserTests {
    @Test func launchctlFixture() {
        let m = Parsers.launchctl(fixture("launchctl-list.txt"))
        #expect(m["redis"] == 99615)
        #expect(m["postgresql@18"] == 44734)
    }

    @Test func launchctlSkipsHeaderAndNonNumeric() {
        let m = Parsers.launchctl("PID\tStatus\tLabel\n-\t0\thomebrew.mxcl.stopped\n42\t0\thomebrew.mxcl.up")
        #expect(m["up"] == 42)
        #expect(m["stopped"] == nil)
    }

    @Test func lsofListenFixture() {
        let m = Parsers.listeningPorts(fixture("lsof-listen.txt"))
        #expect(m[99615] == 6379)
        #expect(m[44734] == 5432)
    }

    @Test func lsofIPv6AndHeader() {
        let out = "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nredis 42 me 6u IPv6 0x0 0t0 TCP [::1]:6379 (LISTEN)"
        #expect(Parsers.listeningPorts(out)[42] == 6379)
    }

    @Test func lsofFieldsFixture() {
        let rows = Parsers.lsofFields(fixture("lsof-fields.txt"))
        #expect(rows.contains { $0.pid == 620 && $0.port == 7000 && $0.command == "ControlCenter" })
        #expect(rows.contains { $0.pid == 620 && $0.port == 5000 })
    }

    @Test func lsofFieldsSpacesAndWildcard() {
        let rows = Parsers.lsofFields("p42\ncGoogle Chrome\nLme\ntIPv4\nn*:8080")
        #expect(rows.count == 1)
        #expect(rows[0].command == "Google Chrome")
        #expect(rows[0].port == 8080)
    }

    @Test func etimeFormats() {
        #expect(Parsers.etime("44:35") == 44 * 60 + 35)
        #expect(Parsers.etime("05:50:48") == 5 * 3600 + 50 * 60 + 48)
        #expect(Parsers.etime("01-10:32:41") == ((24 + 10) * 60 + 32) * 60 + 41)
        #expect(Parsers.etime("garbage") == nil)
    }

    @Test func psFixture() {
        let s = Parsers.ps(fixture("ps-stats.txt"))[99615]
        #expect(s?.rssBytes == 2160 * 1024)
        #expect((s?.uptimeSecs ?? 0) > 0)
    }

    @Test func plistLogPath() {
        #expect(Parsers.logPath(fromPlist: "<key>StandardOutPath</key>\n\t<string>/opt/homebrew/var/log/redis.log</string>")
            == "/opt/homebrew/var/log/redis.log")
        #expect(Parsers.logPath(fromPlist: "<key>Label</key><string>x</string>") == nil)
    }
}

@Suite struct ValidateTests {
    @Test func acceptsRealFormulae() {
        for n in ["redis", "postgresql@18", "mongodb-community", "mongodb/brew/mongodb-community@7.0"] {
            #expect(Validate.isFormula(n))
        }
    }

    @Test func rejectsInjectionAndJunk() {
        for n in ["redis; rm -rf /", "../etc/passwd", "a/../b", "Redis", "", "mongodb/brew", "a/b/c/d", "-rf"] {
            #expect(!Validate.isFormula(n), "\(n)")
        }
    }

    @Test func tapsAreUserSlashRepo() {
        #expect((try? Validate.tap("mongodb/brew")) != nil)
        #expect((try? Validate.tap("mongodb")) == nil)
        #expect((try? Validate.tap("mongodb/brew/x")) == nil)
        #expect((try? Validate.tap("../etc")) == nil)
    }

    @Test func stripsTapPrefix() {
        #expect(bareFormula("mongodb/brew/mongodb-community@7.0") == "mongodb-community@7.0")
        #expect(bareFormula("redis") == "redis")
    }
}

@Suite struct BrewErrorTests {
    static let lockErr = "lockf: 200: already locked Error: Another `brew vendor-install ruby` process is already running. Please wait for it to finish or terminate it to continue.\nError: Failed to upgrade Homebrew Portable Ruby!"
    static let rubyCrash = "Error: undefined method `service_name'\n/opt/homebrew/Library/Homebrew/formulary.rb:351:in 'block (3 levels) in Formulary.load_formula_from_struct!'\n/opt/homebrew/Library/Homebrew/service.rb:63:in 'Homebrew::Service#initialize'\n/opt/homebrew/Library/Homebrew/brew.rb:121:in '<main>'\nPlease report this issue: https://docs.brew.sh/Troubleshooting"
    static let untrusted = "Error: Refusing to load formula mongodb/brew/mongodb-community@7.0 from untrusted tap mongodb/brew.\nRun `brew trust --formula mongodb/brew/mongodb-community@7.0` or `brew trust mongodb/brew` to trust it."

    @Test func lockContentionIsBusy() {
        #expect(Brew.classify(stderr: Self.lockErr).kind == "busy")
    }

    @Test func rubyBacktraceIsStripped() {
        guard case let .shell(msg) = Brew.classify(stderr: Self.rubyCrash) else { Issue.record("expected shell"); return }
        #expect(msg.hasPrefix("Error: undefined method"))
        #expect(!msg.contains(".rb:"))
        #expect(!msg.contains("docs.brew.sh"))
        #expect(msg.count < 120)
    }

    @Test func untrustedTapCarriesTheTap() {
        #expect(Brew.classify(stderr: Self.untrusted) == .untrustedTap("mongodb/brew"))
        #expect(Brew.classify(stderr: "Error: No such keg").kind == "shell")
        #expect(Brew.untrustedTap("from untrusted tap ../../etc.") == nil)
    }

    @Test func emptyStderrStillSaysSomething() {
        #expect(Brew.classify(stderr: "   \n  ") == .shell("Homebrew command failed"))
    }
}

@Suite struct ServicesTests {
    static let redisSearch = "hiredis\niredis\nredis\nredis-leveldb\nredis@6.2\nredis@8.2\nredir\nredli\n"

    @Test func versionsAreBaseAndVariants() {
        #expect(ServicesBackend.pickVersions(Self.redisSearch, base: "redis") == ["redis", "redis@6.2", "redis@8.2"])
    }

    @Test func fallsBackToRenamedTapBuild() {
        #expect(ServicesBackend.pickVersions("elastic/tap/elasticsearch-full\n\nelasticvue\n", base: "elasticsearch")
            == ["elastic/tap/elasticsearch-full"])
    }

    @Test func parsesServicesJSON() throws {
        let entries = try JSONDecoder().decode([BrewServiceEntry].self, from: Data(fixture("brew-services-list.json").utf8))
        let redis = try #require(entries.first { $0.name == "redis" })
        #expect(redis.status == "started")
        #expect(redis.file != nil)
    }

    @Test func cacheTracksPidMapAndTTL() async {
        let cache = ServicesCache()
        let pids = ["redis": Int32(100)]
        await cache.store([], pids: pids)
        #expect(await cache.fresh(pids: pids) != nil)
        #expect(await cache.fresh(pids: ["redis": 200]) == nil)
        #expect(await cache.fresh(pids: pids, now: Date().addingTimeInterval(61)) == nil)
        await cache.invalidate()
        #expect(await cache.fresh(pids: pids) == nil)
    }

    @Test func busyBrewServesStaleInsteadOfRacing() async throws {
        let backend = ServicesBackend(brew: Brew(context: AppContext(arch: "aarch64", brewPrefix: nil, brewBin: "/nonexistent/brew")))
        await backend.cache.store([BrewServiceEntry(name: "redis", status: "started", file: nil)], pids: [:],
                                  at: Date().addingTimeInterval(-120))
        await backend.brew.lock.lock()
        let out = try await backend.fetchList(pids: ["redis": 1])
        #expect(out.map(\.name) == ["redis"])
        await backend.brew.lock.unlock()
    }

    @Test func busyBrewWithNoCacheReportsBusy() async {
        let backend = ServicesBackend(brew: Brew(context: AppContext(arch: "aarch64", brewPrefix: nil, brewBin: "/nonexistent/brew")))
        await backend.brew.lock.lock()
        await #expect(throws: AppError.busy(Brew.busyMessage)) { try await backend.fetchList(pids: [:]) }
        await backend.brew.lock.unlock()
    }
}

@Suite struct ReconcileTests {
    @Test func mapsStatus() {
        func s(_ status: String, healthy: Bool? = nil) -> ServiceInfo {
            ServiceInfo(name: "x", status: status, healthy: healthy)
        }
        #expect(Reconcile.status(nil) == .notInstalled)
        #expect(Reconcile.status(s("started")) == .running)
        #expect(Reconcile.status(s("started", healthy: false)) == .starting)
        #expect(Reconcile.status(s("none")) == .stopped)
        #expect(Reconcile.status(s("error")) == .error)
    }

    @Test func matchesTapQualifiedOnBareName() {
        let out = Reconcile.merge(
            managed: [ManagedService(formula: "mongodb/brew/mongodb-community@7.0", displayName: "Mongo")],
            brew: [ServiceInfo(name: "mongodb-community@7.0", status: "started", pid: 7)],
            intent: [:])
        #expect(out[0].status == .running)
        #expect(out[0].pid == 7)
        #expect(out[0].linkState == .unlinked)
    }
}

@Suite struct SettingsTests {
    @Test func lenientDecodeFallsBackToDefaults() throws {
        let json = #"{"theme":"dark","pollIntervalMs":"junk","enabledModules":["claude","bogus"]}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.theme == .dark)
        #expect(s.pollIntervalMs == 4000)
        #expect(s.enabledModules == [.claude])
        #expect(!s.isEnabled(.homebrew))
    }

    @Test func emptyModuleListFailsOpen() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"enabledModules":[]}"#.utf8))
        #expect(s.enabledModules == nil)
        #expect(s.isEnabled(.homebrew))
    }

    @Test func formatters() {
        #expect(Format.bytes(2160 * 1024) == "2.1 MB")
        #expect(Format.duration(5 * 3600 + 50 * 60) == "5h 50m")
        #expect(Format.formulaDisplayName("mongodb/brew/mongodb-community@7.0") == "Mongodb Community")
    }

    @Test func journalParsesLines() {
        let e = Journal.parse(#"{"tsEpoch":1700000000,"action":"archive","project":"x","moved":3}"#)
        #expect(e?.action == "archive")
        #expect(e?.detail == "moved 3 · project x")
        #expect(Journal.parse("not json") == nil)
        #expect(Journal.parse(#"{"noAction":true}"#) == nil)
    }
}
