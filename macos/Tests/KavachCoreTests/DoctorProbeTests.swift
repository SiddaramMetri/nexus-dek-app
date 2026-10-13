import Foundation
import Testing
@testable import KavachCore

@Suite struct DoctorSystemProbeTests {
    @Test func severitySortsRedFirst() {
        #expect(Severity.red < .yellow)
        #expect(Severity.yellow < .green)
    }

    @Test func diskThresholds() {
        #expect(SystemProbes.classifyDisk(5_000_000_000) == .red)
        #expect(SystemProbes.classifyDisk(15_000_000_000) == .yellow)
        #expect(SystemProbes.classifyDisk(100_000_000_000) == .green)
    }

    @Test func loadThresholds() {
        #expect(SystemProbes.classifyLoad(2.0, cores: 8) == .green)
        #expect(SystemProbes.classifyLoad(9.5, cores: 8) == .yellow)
        #expect(SystemProbes.classifyLoad(16.0, cores: 8) == .red)
    }

    @Test func parsesLowPowerMode() {
        #expect(SystemProbes.parseLowPower(" SleepDisabled\t\t0\n lowpowermode         1\n standby              1") == true)
        #expect(SystemProbes.parseLowPower(" lowpowermode         0") == false)
        #expect(SystemProbes.parseLowPower("no such key here") == nil)
    }

    @Test func parsesSwapUsed() {
        #expect(SystemProbes.parseSwapUsedMB("total = 2048.00M  used = 512.50M  free = 1535.50M  (encrypted)") == 512.5)
        #expect(SystemProbes.parseSwapUsedMB("vm.swapusage: total = 1024.00M  used = 0.00M  free = 1024.00M") == 0)
        #expect(SystemProbes.parseSwapUsedMB("garbage") == nil)
    }

    @Test func memoryThresholds() {
        #expect(SystemProbes.classifyMemory(level: 1, swapMB: 0) == .green)
        #expect(SystemProbes.classifyMemory(level: 1, swapMB: 3000) == .yellow)
        #expect(SystemProbes.classifyMemory(level: 2, swapMB: 0) == .yellow)
        #expect(SystemProbes.classifyMemory(level: 4, swapMB: 0) == .red)
    }

    @Test func parsesThirdPartyLabels() {
        let out = "PID\tStatus\tLabel\n1234\t0\tcom.apple.Finder\n-\t0\tcom.apple.mdworker.shared\n"
            + "567\t0\tcom.facebook.watchman\n-\t1\thomebrew.mxcl.redis"
        #expect(SystemProbes.parseThirdPartyLabels(out) == ["com.facebook.watchman", "homebrew.mxcl.redis"])
    }

    @Test func parsesTMDestination() {
        let configured = "==================================================\nName          : Backup HD\nKind          : Local\n"
        #expect(SystemProbes.parseTMName(configured) == "Backup HD")
        #expect(SystemProbes.parseTMName("tmutil: No destinations configured.") == nil)
    }

    // Real machine, read-only: every probe returns at most one finding and
    // never crashes (LPM may return zero on Macs without the setting).
    @Test func probesRunOnRealMachine() async {
        #expect(await SystemProbes.runDiskFree().count == 1)
        #expect(await SystemProbes.runLoadVsCores().count == 1)
        #expect(await SystemProbes.runLowPower().count <= 1)
        #expect(await SystemProbes.runMemoryTruth().count == 1)
        #expect(await SystemProbes.runBackupRisk().count == 1)
        #expect(await SystemProbes.runStartupItems().count == 1)
    }
}

@Suite struct DoctorOllamaTests {
    static let manifest = """
    {
      "schemaVersion": 2,
      "config": {"digest": "sha256:cfg", "size": 487},
      "layers": [
        {"digest": "sha256:model", "size": 1929903072},
        {"digest": "sha256:tmpl", "size": 1615}
      ]
    }
    """

    @Test func parsesManifestBlobs() throws {
        let blobs = try #require(OllamaProbe.parseManifest(Self.manifest))
        #expect(blobs.count == 3)
        #expect(blobs[1] == .init(digest: "sha256:model", size: 1_929_903_072))
        #expect(OllamaProbe.weightsDigest(blobs) == "sha256:model")
        // Fail-safe: unrecognized shapes are refused.
        #expect(OllamaProbe.parseManifest(#"{"layers": "nope"}"#) == nil)
        #expect(OllamaProbe.parseManifest("garbage") == nil)
    }

    @Test func dedupesSharedBlobsAndFlagsStale() {
        typealias B = OllamaProbe.Blob
        let a = OllamaProbe.ModelInfo(name: "a:latest", digests: [B(digest: "s:shared", size: 100), B(digest: "s:a", size: 10)],
                                      pulledEpoch: 1_000_000, lastUsedEpoch: 0, inUse: false)
        let b = OllamaProbe.ModelInfo(name: "b:latest", digests: [B(digest: "s:shared", size: 100), B(digest: "s:b", size: 20)],
                                      pulledEpoch: 1_000_000, lastUsedEpoch: 1_000_000 + 86_400 * 199, inUse: false)
        let c = OllamaProbe.ModelInfo(name: "c:latest", digests: [B(digest: "s:c", size: 5)],
                                      pulledEpoch: 1_000_000, lastUsedEpoch: 0, inUse: true)
        let s = OllamaProbe.stats([a, b, c], now: 1_000_000 + 86_400 * 200)
        #expect(s.totalBytes == 135, "shared blob counted once")
        #expect(s.sharedBytes == 100)
        #expect(s.models[0].stale, "old + unused → stale")
        #expect(!s.models[1].stale, "recently USED beats old pull date")
        #expect(!s.models[2].stale, "in use → never stale")
        #expect(s.models[0].bytes == 110, "per-model = its own unique view")
    }

    @Test func deleteRejectsUnknownModelsBeforeSpawning() async {
        await #expect(throws: AppError.self) { try await OllamaProbe.deleteModel("definitely-not-installed:v0") }
    }

    // Real machine, read-only — only manifest files are read, so nothing here
    // could wake the ollama daemon.
    @Test func scansRealModelsWithoutDaemon() async {
        for m in await OllamaProbe.scanModels() {
            #expect(m.name.contains(":"))
            #expect(!m.digests.isEmpty)
        }
    }

    @Test func formatsDecimalSizes() {
        #expect(OllamaProbe.gb(1_929_903_072) == "1.9 GB")
        #expect(OllamaProbe.gb(487_000_000) == "487 MB")
        #expect(DoctorSupport.formatDate(1_784_073_600) == "15 Jul 2026")
    }
}

@Suite struct DoctorBrowserTests {
    @Test func splitsProcessesByFullArgsNotComm() {
        let ps = """
          512000 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
          204800 /Applications/Google Chrome.app/Contents/Frameworks/... --type=renderer --extension-process --lang=en
          102400 /Applications/Google Chrome.app/Contents/Frameworks/... --type=renderer https://example.com
           51200 /Applications/Google Chrome.app/Contents/Frameworks/... --type=gpu-process
           99999 /Applications/Brave Browser.app/Contents/MacOS/Brave Browser
             500 /usr/sbin/somethingelse
        """
        let c = BrowserProbes.parsePS(ps, marker: "Google Chrome.app")
        #expect(c.procs == 4)
        #expect(c.totalKB == 512_000 + 204_800 + 102_400 + 51_200)
        #expect(c.extProcs == 1, "extension renderer counted once, in ext bucket")
        #expect(c.extKB == 204_800)
        #expect(c.rendererKB == 102_400)
        #expect(c.gpuKB == 51_200)
        let b = BrowserProbes.parsePS(ps, marker: "Brave Browser.app")
        #expect(b.procs == 1 && b.totalKB == 99_999)
    }

    @Test func parsesBackgroundModeFailSafe() {
        #expect(BrowserProbes.parseBackgroundMode(#"{"background_mode":{"enabled":true}}"#) == true)
        #expect(BrowserProbes.parseBackgroundMode(#"{"background_mode":{"enabled":false}}"#) == false)
        #expect(BrowserProbes.parseBackgroundMode(#"{"background_mode":{"enabled":1}}"#) == nil)
        #expect(BrowserProbes.parseBackgroundMode(#"{"other":1}"#) == nil)
        #expect(BrowserProbes.parseBackgroundMode("garbage") == nil)
    }

    @Test func clearCacheRejectsUnknownBrowsers() async {
        await #expect(throws: AppError.self) { try await BrowserProbes.clearCache("Netscape") }
    }

    @Test func parsesAudioAssertionOwners() {
        let out = """
           pid 435(coreaudiod): [0x0000d2e9] 00:07:32 PreventUserIdleSystemSleep named: "x"
           pid 812(Google Chrome): [0x0000ffff] 01:00:00 NoIdleSleepAssertion named: "Playing audio"
           pid 812(Google Chrome): [0x0000fffe] 01:00:00 NoIdleSleepAssertion named: "Playing audio"
        """
        #expect(BrowserProbes.parseAudioOwners(out) == ["Google Chrome"])
        #expect(BrowserProbes.parseAudioOwners("nothing here").isEmpty)
    }

    // Real machine, read-only: both probes run without crashing.
    @Test func probesRunOnRealMachine() async {
        _ = await BrowserProbes.runProcesses()
        #expect(await BrowserProbes.runAudio().count == 1)
    }

    @Test func parsesExtManifestNameAndBackground() throws {
        // Plain name, no locale lookup needed → vdir is never read.
        let dir = URL(fileURLWithPath: "/nonexistent")
        let ublock = try #require(BrowserProbes.parseExtManifest(
            #"{"name":"uBlock Origin","background":{"service_worker":"sw.js"}}"#, vdir: dir))
        #expect(ublock.0 == "uBlock Origin" && ublock.1)
        let json = try #require(BrowserProbes.parseExtManifest(#"{"name":"JSON Formatter"}"#, vdir: dir))
        #expect(json.0 == "JSON Formatter" && !json.1)
        // Unresolvable __MSG__ (locale file missing) falls back to the raw name.
        let msg = try #require(BrowserProbes.parseExtManifest(
            #"{"name":"__MSG_extName__","default_locale":"en"}"#, vdir: dir))
        #expect(msg.0 == "__MSG_extName__" && !msg.1)
        #expect(BrowserProbes.parseExtManifest("garbage", vdir: dir) == nil)
    }

    @Test func looksUpLocalizedMessagesCaseInsensitively() {
        let msgs = #"{"extName":{"message":"Google Docs Offline"}}"#
        #expect(BrowserProbes.lookupMessage(msgs, key: "extName") == "Google Docs Offline")
        #expect(BrowserProbes.lookupMessage(msgs, key: "extname") == "Google Docs Offline")
        #expect(BrowserProbes.lookupMessage(msgs, key: "missing") == nil)
        #expect(BrowserProbes.lookupMessage("garbage", key: "extName") == nil)
    }

    @Test func manageExtensionRejectsUnknownTargets() async {
        await #expect(throws: AppError.self) { try await BrowserProbes.manageExtension("Netscape:abc") }
        await #expect(throws: AppError.self) { try await BrowserProbes.manageExtension("no-colon") }
    }

    // Real machine, read-only: always at least one finding (overview or "none").
    @Test func extensionsProbeProducesAFinding() async {
        #expect(!(await BrowserProbes.runExtensions()).isEmpty)
    }
}

@Suite struct DoctorDeepScanTests {
    // This predicate decides a multi-GB delete, so every way it could pick the
    // WRONG directory gets a case.
    @Test func onlySupersededStoreVersionsAreOrphans() {
        #expect(DeepScan.isOrphanStore("v10", active: "v11"), "pnpm moved off v10")
        #expect(!DeepScan.isOrphanStore("v11", active: "v11"), "never the live store")
        // Can't ask pnpm which one is live → nothing is deletable.
        #expect(!DeepScan.isOrphanStore("v10", active: nil))
        for name in ["tmp", "v", "v10x", "backup-v10", ".DS_Store", "v١٠"] {
            #expect(!DeepScan.isOrphanStore(name, active: "v11"), "\(name) is not a store")
        }
    }

    @Test func classifiesByLocationAndAge() {
        #expect(DeepScan.classify(inDownloads: true, projectAgeDays: 0) == .dead, "Downloads is always dead")
        #expect(DeepScan.classify(inDownloads: false, projectAgeDays: 200) == .dead)
        #expect(DeepScan.classify(inDownloads: false, projectAgeDays: 60) == .stale)
        #expect(DeepScan.classify(inDownloads: false, projectAgeDays: 5) == .active)
    }

    @Test func parsesDuOutput() {
        #expect(DoctorSupport.parseDuKB("487344\t/Users/x/node_modules") == 487_344)
        #expect(DoctorSupport.parseDuKB("garbage") == nil)
    }

    @Test func fixWhitelistRejectsUnknownIds() async {
        await #expect(throws: AppError.self) { try await DeepScan.fix("rm_-rf_slash") }
        await #expect(throws: AppError.self) { try await DeepScan.fix("cache_unknown") }
    }

    @Test func findArgsPruneMediaAndLibrary() {
        let args = DeepScan.findArgs(home: "/Users/x")
        for pruned in ["/Users/x/Library", "/Users/x/.Trash", "/Users/x/Music", "/Users/x/Pictures", "/Users/x/Movies"] {
            #expect(args.contains(pruned))
        }
        #expect(Array(args.suffix(3)) == ["node_modules", "-print", "-prune"])
    }

    // Real machine, read-only: the bounded find must only return top-level
    // node_modules dirs.
    @Test func findsRealNodeModules() async {
        for nm in await DeepScan.findNodeModules() {
            #expect(nm.lastPathComponent == "node_modules")
            #expect(!nm.deletingLastPathComponent().path.contains("node_modules"))
        }
    }
}
