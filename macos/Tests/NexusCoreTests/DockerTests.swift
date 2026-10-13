import Foundation
import Testing
@testable import NexusCore

/// Sample output in the docker CLI's `--format '{{json .}}'` shapes (Docker 28).
enum DockerFixtures {
    static let df = """
    {"Active":"3","Reclaimable":"1.2GB (45%)","Size":"2.637GB","TotalCount":"6","Type":"Images"}
    {"Active":"1","Reclaimable":"12.29kB (50%)","Size":"24.58kB","TotalCount":"3","Type":"Containers"}
    {"Active":"1","Reclaimable":"151.6MB (61%)","Size":"246.8MB","TotalCount":"3","Type":"Local Volumes"}
    {"Active":"0","Reclaimable":"1.234GB","Size":"1.234GB","TotalCount":"35","Type":"Build Cache"}
    """

    static let images = """
    {"Containers":"N/A","CreatedAt":"2024-05-01 10:22:33 +0530 IST","CreatedSince":"17 months ago","Digest":"\\u003cnone\\u003e","ID":"a1b2c3d4e5f6","Repository":"postgres","SharedSize":"N/A","Size":"432MB","Tag":"16","UniqueSize":"N/A","VirtualSize":"432.1MB"}
    {"Containers":"N/A","CreatedAt":"2025-01-10 08:00:00 +0000 UTC","CreatedSince":"9 months ago","Digest":"\\u003cnone\\u003e","ID":"0123456789ab","Repository":"redis","SharedSize":"N/A","Size":"117MB","Tag":"latest","UniqueSize":"N/A","VirtualSize":"117MB"}
    {"Containers":"N/A","CreatedAt":"2025-06-02 12:30:00 +0530 IST","CreatedSince":"4 months ago","Digest":"\\u003cnone\\u003e","ID":"deadbeef0001","Repository":"\\u003cnone\\u003e","SharedSize":"N/A","Size":"1.1GB","Tag":"\\u003cnone\\u003e","UniqueSize":"N/A","VirtualSize":"1.1GB"}
    {"Containers":"N/A","CreatedAt":"2025-07-01 09:00:00 +0530 IST","CreatedSince":"3 months ago","Digest":"\\u003cnone\\u003e","ID":"cafebabe0002","Repository":"myapp","SharedSize":"N/A","Size":"812MB","Tag":"dev","UniqueSize":"N/A","VirtualSize":"812MB"}
    {"Containers":"N/A","CreatedAt":"2025-07-03 09:00:00 +0530 IST","CreatedSince":"3 months ago","Digest":"\\u003cnone\\u003e","ID":"feedface0003","Repository":"node","SharedSize":"N/A","Size":"1.12GB","Tag":"20-alpine","UniqueSize":"N/A","VirtualSize":"1.12GB"}
    {"Containers":"N/A","CreatedAt":"2025-07-04 09:00:00 +0530 IST","CreatedSince":"3 months ago","Digest":"\\u003cnone\\u003e","ID":"0badf00d0004","Repository":"ghcr.io/acme/api","SharedSize":"N/A","Size":"95.3MB","Tag":"1.2.0","UniqueSize":"N/A","VirtualSize":"95.3MB"}
    """

    static let ps = """
    {"Command":"\\"docker-entrypoint.s…\\"","CreatedAt":"2025-02-01 10:00:00 +0530 IST","ID":"f00dfeed1234","Image":"postgres:16","Labels":"com.docker.compose.project=shop","LocalVolumes":"1","Mounts":"pgdata","Names":"shop-db-1","Networks":"bridge","Ports":"0.0.0.0:5432-\\u003e5432/tcp","RunningFor":"8 months ago","Size":"0B","State":"running","Status":"Up 2 hours"}
    {"Command":"\\"redis-server\\"","CreatedAt":"2025-03-01 10:00:00 +0530 IST","ID":"beefbeef5678","Image":"redis","Labels":"","LocalVolumes":"1","Mounts":"3f6c…","Names":"cache","Networks":"bridge","Ports":"","RunningFor":"7 months ago","Size":"0B","State":"exited","Status":"Exited (0) 3 days ago"}
    {"Command":"\\"node index.js\\"","CreatedAt":"2025-07-05 10:00:00 +0530 IST","ID":"abcabcabc999","Image":"0badf00d0004","Labels":"","LocalVolumes":"0","Mounts":"","Names":"old-api","Networks":"bridge","Ports":"","RunningFor":"3 months ago","Size":"0B","State":"created","Status":"Created"}
    """

    static let volumes = """
    {"Availability":"N/A","Driver":"local","Group":"N/A","Labels":"com.docker.compose.project=shop,com.docker.compose.volume=pgdata","Links":"N/A","Mountpoint":"/var/lib/docker/volumes/shop_pgdata/_data","Name":"shop_pgdata","Scope":"local","Size":"N/A","Status":"N/A"}
    {"Availability":"N/A","Driver":"local","Group":"N/A","Labels":"","Links":"N/A","Mountpoint":"/var/lib/docker/volumes/3f6c1d2e4a5b6c7d8e9f00112233445566778899aabbccddeeff001122334455/_data","Name":"3f6c1d2e4a5b6c7d8e9f00112233445566778899aabbccddeeff001122334455","Scope":"local","Size":"N/A","Status":"N/A"}
    {"Availability":"N/A","Driver":"local","Group":"N/A","Labels":"com.docker.compose.project=old","Links":"N/A","Mountpoint":"/var/lib/docker/volumes/old_mysql/_data","Name":"old_mysql","Scope":"local","Size":"N/A","Status":"N/A"}
    {"Availability":"N/A","Driver":"local","Group":"N/A","Labels":"","Links":"N/A","Mountpoint":"/var/lib/docker/volumes/9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a/_data","Name":"9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a","Scope":"local","Size":"N/A","Status":"N/A"}
    """

    static let dangling = """
    old_mysql
    9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a
    """

    static let verbose = """
    {"BuildCache":[],"Containers":[{"ID":"f00dfeed1234","Image":"postgres:16","Names":"shop-db-1","Size":"1.2kB (virtual 432MB)","State":"running"},{"ID":"beefbeef5678","Image":"redis","Names":"cache","Size":"12.29kB (virtual 117MB)","State":"exited"}],"Images":[{"Containers":"1","ID":"a1b2c3d4e5f6","Repository":"postgres","SharedSize":"0B","Size":"432MB","Tag":"16","UniqueSize":"432MB"},{"Containers":"0","ID":"cafebabe0002","Repository":"myapp","SharedSize":"700MB","Size":"812MB","Tag":"dev","UniqueSize":"112MB"},{"Containers":"2","ID":"feedface0003","Repository":"node","SharedSize":"0B","Size":"1.12GB","Tag":"20-alpine","UniqueSize":"1.12GB"}],"Volumes":[{"Driver":"local","Links":"1","Name":"shop_pgdata","Size":"95.2MB"},{"Driver":"local","Links":"0","Name":"old_mysql","Size":"150MB"},{"Driver":"local","Links":"0","Name":"9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a","Size":"1.6MB"}]}
    """

    static let inspectImages = "sha256:a1b2c3d4e5f6000000000000000000000000000000000000000000000000abcd\n"

    static func snapshot() -> DockerSnapshot {
        let containers = DockerParse.containers(ps)
        let images = DockerParse.markInUse(DockerParse.images(images), containers: containers,
                                           containerImageIDs: DockerParse.names(inspectImages))
        return DockerSnapshot(usage: DockerParse.usage(df), images: images, containers: containers,
                              volumes: DockerParse.volumes(volumes, dangling: DockerParse.names(dangling)))
    }
}

@Suite struct DockerSizeTests {
    @Test(arguments: [
        ("1.23GB", UInt64(1_230_000_000)), ("512MB", 512_000_000), ("0B", 0), ("1.09kB", 1_090),
        ("246.8MB", 246_800_000), ("2.637GB", 2_637_000_000), ("1.5TB", 1_500_000_000_000), ("42B", 42),
        ("1.2GB (45%)", 1_200_000_000), ("12.29kB (virtual 117MB)", 12_290), ("  3MB ", 3_000_000),
        ("1KiB", 1_024), ("2MiB", 2_097_152), ("1GiB", 1_073_741_824), ("1.5 GB", 1_500_000_000),
    ])
    func parses(raw: String, bytes: UInt64) {
        #expect(DockerParse.bytes(raw) == bytes)
    }

    @Test(arguments: ["N/A", "", "GB", "abc", "-1MB", "12XB"])
    func rejects(raw: String) {
        #expect(DockerParse.bytes(raw) == nil)
    }

    @Test func reclaimedLine() {
        #expect(DockerParse.reclaimed("Deleted Images:\ndeleted: sha256:abc\n\nTotal reclaimed space: 1.234GB\n") == 1_234_000_000)
        #expect(DockerParse.reclaimed("Total reclaimed space: 0B") == 0)
        #expect(DockerParse.reclaimed("nothing here") == nil)
    }
}

@Suite struct DockerParseTests {
    @Test func usageRows() {
        let u = DockerParse.usage(DockerFixtures.df)
        #expect(u.map(\.kind) == [.images, .containers, .volumes, .buildCache])
        #expect(u[0].total == 6 && u[0].active == 3)
        #expect(u[0].bytes == 2_637_000_000 && u[0].reclaimable == 1_200_000_000)
        #expect(u[3].reclaimable == 1_234_000_000)
    }

    @Test func reclaimableMath() {
        let s = DockerFixtures.snapshot()
        #expect(s.totalBytes == 2_637_000_000 + 24_580 + 246_800_000 + 1_234_000_000)
        #expect(s.reclaimableBytes == 1_200_000_000 + 12_290 + 151_600_000 + 1_234_000_000)
        #expect(s.usage(.volumes)?.reclaimable == 151_600_000)
    }

    @Test func imageRows() {
        let imgs = DockerParse.images(DockerFixtures.images)
        #expect(imgs.count == 6)
        #expect(imgs[0].reference == "postgres:16" && imgs[0].bytes == 432_000_000)
        #expect(imgs[0].removeArg == "postgres:16")
        let dangling = imgs[2]
        #expect(dangling.isDangling && dangling.reference == "<none>" && dangling.removeArg == "deadbeef0001")
        #expect(imgs[0].created != nil)
        #expect(Set(imgs.map(\.id)).count == imgs.count)
    }

    @Test func containerRows() {
        let cs = DockerParse.containers(DockerFixtures.ps)
        #expect(cs.map(\.name) == ["shop-db-1", "cache", "old-api"])
        #expect(cs[0].isRunning && !cs[0].removable)
        #expect(cs[1].removable && cs[1].state == "exited")
        #expect(cs[2].removable && cs[2].state == "created")
    }

    @Test func stateFallsBackToStatus() {
        let cs = DockerParse.containers(#"{"ID":"aaaaaaaaaaaa","Names":"x","Image":"y","Status":"Up 3 minutes (Paused)"}"#
            + "\n" + #"{"ID":"bbbbbbbbbbbb","Names":"z","Image":"y","Status":"Exited (137) 2 days ago"}"#)
        #expect(cs[0].state == "paused" && !cs[0].removable)
        #expect(cs[1].state == "exited" && cs[1].removable)
    }

    @Test func volumeRows() {
        let vs = DockerParse.volumes(DockerFixtures.volumes, dangling: DockerParse.names(DockerFixtures.dangling))
        #expect(vs.count == 4)
        let byName = Dictionary(uniqueKeysWithValues: vs.map { ($0.name, $0) })
        #expect(byName["shop_pgdata"]?.dangling == false)
        #expect(byName["shop_pgdata"]?.composeProject == "shop")
        #expect(byName["old_mysql"]?.removable == true && byName["old_mysql"]?.isAnonymous == false)
        let anon = vs.filter(\.isAnonymous)
        #expect(anon.count == 2)
        #expect(anon.filter(\.dangling).count == 1)
    }

    @Test func junkLinesSkipped() {
        #expect(DockerParse.jsonLines("WARNING: something\n\n{\"ID\":\"x\"}\nnot json {").count == 1)
        #expect(DockerParse.images("").isEmpty)
    }

    @Test func verboseSizes() throws {
        let v = try #require(DockerParse.verbose(DockerFixtures.verbose))
        #expect(v.volumes["old_mysql"] == 150_000_000)
        #expect(v.volumeLinks["shop_pgdata"] == 1)
        #expect(v.containers["beefbeef5678"] == 12_290)
        #expect(v.imageUnique["cafebabe0002"] == 112_000_000)
        #expect(v.imageContainers["feedface0003"] == 2)
        #expect(DockerParse.verbose("not json") == nil)
    }

    @Test func applySizes() throws {
        let s = DockerFixtures.snapshot()
        let v = try #require(DockerParse.verbose(DockerFixtures.verbose))
        let carried = DockerCleaner.apply(v, to: s, usage: false)
        #expect(carried.images.first { $0.imageID == "feedface0003" }?.inUse == false)
        let applied = DockerCleaner.apply(v, to: s)
        let node = try #require(applied.images.first { $0.imageID == "feedface0003" })
        #expect(node.inUse && !node.removable)
        #expect(applied.images.first { $0.imageID == "cafebabe0002" }?.freeableBytes == 112_000_000)
        #expect(applied.volumes.first { $0.name == "old_mysql" }?.bytes == 150_000_000)
        #expect(applied.containers.first { $0.id == "beefbeef5678" }?.bytes == 12_290)
    }

    @Test func daemonDown() {
        #expect(DockerParse.isDaemonDown("failed to connect to the docker API at unix:///var/run/docker.sock; check if the path is correct and if the daemon is running: dial unix /var/run/docker.sock: connect: no such file or directory"))
        #expect(DockerParse.isDaemonDown("Cannot connect to the Docker daemon at unix:///Users/me/.colima/default/docker.sock. Is the docker daemon running?"))
        #expect(!DockerParse.isDaemonDown("Error response from daemon: conflict: unable to remove repository reference"))
    }

    @Test func dateParsing() throws {
        let d = try #require(DockerParse.date("2024-05-01 10:22:33 +0530 IST"))
        #expect(d.timeIntervalSince1970 == 1_714_539_153)
        #expect(DockerParse.date("garbage") == nil)
    }
}

@Suite struct DockerClassificationTests {
    @Test func inUseByNameIdAndInspect() {
        let s = DockerFixtures.snapshot()
        let use = Dictionary(uniqueKeysWithValues: s.images.map { ($0.imageID, $0.inUse) })
        #expect(use["a1b2c3d4e5f6"] == true)   // postgres:16, by name and by inspect id
        #expect(use["0123456789ab"] == true)   // `redis` means redis:latest, stopped container counts
        #expect(use["0badf00d0004"] == true)   // container created from a bare image id
        #expect(use["cafebabe0002"] == false)
        #expect(use["feedface0003"] == false)
        #expect(use["deadbeef0001"] == false)
    }

    @Test func refMatching() {
        let img = DockerImage(imageID: "0123456789ab", repository: "redis", tag: "7", bytes: nil, created: nil,
                              createdSince: "", inUse: false)
        #expect(DockerParse.refMatches("redis:7", img))
        #expect(DockerParse.refMatches("docker.io/library/redis:7", img))
        #expect(DockerParse.refMatches("redis@sha256:abcd", img))
        #expect(!DockerParse.refMatches("redis", img))           // = redis:latest
        #expect(!DockerParse.refMatches("redis:6", img))
        #expect(DockerParse.refMatches("sha256:0123456789abcdef", img))
        let port = DockerImage(imageID: "111111111111", repository: "localhost:5000/app", tag: "latest", bytes: nil,
                               created: nil, createdSince: "", inUse: false)
        #expect(DockerParse.refMatches("localhost:5000/app", port))
        #expect(!DockerParse.refMatches("localhost:5000/app:2", port))
    }

    @Test func danglingAndPrunable() {
        let s = DockerFixtures.snapshot()
        #expect(s.danglingImages.map(\.imageID) == ["deadbeef0001"])
        #expect(s.stoppedContainers.map(\.name) == ["cache", "old-api"])
        #expect(s.unusedVolumes.map(\.name).sorted() == ["9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a", "old_mysql"])
        #expect(s.prunableVolumes.count == 1)   // named old_mysql is not taken by `volume prune`
    }

    @Test func prunePlans() throws {
        let v = try #require(DockerParse.verbose(DockerFixtures.verbose))
        let s = DockerCleaner.apply(v, to: DockerFixtures.snapshot())
        #expect(DockerPrune.danglingImages.plan(s).count == 1)
        #expect(DockerPrune.danglingImages.plan(s).bytes == 1_100_000_000)
        #expect(DockerPrune.stoppedContainers.plan(s).count == 2)
        #expect(DockerPrune.stoppedContainers.plan(s).bytes == 12_290)
        #expect(DockerPrune.buildCache.plan(s).bytes == 1_234_000_000)
        #expect(DockerPrune.unusedVolumes.plan(s) == (1, 1_600_000))
        let unmeasured = DockerFixtures.snapshot()
        #expect(DockerPrune.unusedVolumes.plan(unmeasured).bytes == nil)
    }

    @Test func confirmCopyNamesWhatGoes() {
        let s = DockerFixtures.snapshot()
        let vol = DockerPrune.unusedVolumes.confirmText(s)
        #expect(vol.message.contains("database data") && vol.message.contains("no undo"))
        #expect(vol.action == "Delete volumes")
        #expect(DockerPrune.buildCache.confirmText(s).message.contains("1.1 GB"))
        #expect(DockerPrune.allCases.allSatisfy { !$0.args.contains("-a") && !$0.args.contains("--volumes") })
        #expect(DockerPrune.allCases.allSatisfy { $0.args.last == "-f" })
    }

    @Test func listTruncates() {
        let names = (1...10).map { "v\($0)" }
        let text = DockerActions.list(names)
        #expect(text.contains("• v8") && !text.contains("• v9") && text.hasSuffix("…and 2 more"))
    }
}

@Suite struct DockerValidateTests {
    @Test(arguments: [
        "a1b2c3d4e5f6", String(repeating: "f", count: 64), "postgres:16", "ghcr.io/acme/api:1.2.0",
        "localhost:5000/app@sha256:abc", "shop_pgdata", "my-volume.v2", "Redis",
    ])
    func accepts(_ s: String) {
        #expect(DockerValidate.isValid(s))
    }

    @Test(arguments: [
        "", "-f", "--all", ".hidden", "_x", "a b", "a;rm -rf", "$(id)", "a`b`", "name\n", "../etc", "ünïcode",
        String(repeating: "a", count: 256),
    ])
    func rejects(_ s: String) {
        #expect(!DockerValidate.isValid(s))
        #expect(throws: AppError.self) { try DockerValidate.target(s) }
    }

    @Test func hexIDs() {
        #expect(DockerValidate.isHexID("0123456789ab"))
        #expect(!DockerValidate.isHexID("0123456789a"))          // too short
        #expect(!DockerValidate.isHexID("0123456789AB"))         // docker ids are lowercase
        #expect(!DockerValidate.isHexID(String(repeating: "a", count: 65)))
    }

    @Test func notInstalledNeverRunsDocker() {
        // Pure file check: same answer twice, and it agrees with the candidate list.
        let expected = DockerCleaner.candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
        #expect(DockerCleaner.isInstalled == expected)
    }
}
