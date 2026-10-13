import Foundation

/// Docker disk usage: what images, containers, volumes and build cache take,
/// and removing what isn't used. Reads never start anything: when the daemon
/// or Colima VM is down, the CLI fails fast on the socket and we report
/// `.notRunning`. Every mutation confirms inside this module and is journaled.
public enum DockerCleaner {
    /// Where a docker CLI lives (Homebrew/Colima, Docker Desktop, Rancher, OrbStack).
    static var candidates: [String] {
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin/docker", "/usr/local/bin/docker",
                "/Applications/Docker.app/Contents/Resources/bin/docker",
                "\(home)/.rd/bin/docker", "\(home)/.orbstack/bin/docker"]
    }

    /// A docker CLI exists on this Mac (checking never starts a daemon or VM).
    public static var isInstalled: Bool {
        candidates.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var binary: String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    /// Reads must answer quickly; a hung daemon must never freeze the tab.
    static let readTimeout: Duration = .seconds(8)
    /// `system df -v` walks every volume inside the VM.
    static let measureTimeout: Duration = .seconds(45)
    /// Removing a big build cache can take a while.
    static let writeTimeout: Duration = .seconds(300)

    // MARK: - Running docker

    /// Runs docker with an args array, killing it after `timeout`.
    static func run(_ args: [String], timeout: Duration) async throws -> ProcOutput {
        guard let bin = binary else { throw DockerUnavailable.notInstalled }
        let result = try await withThrowingTaskGroup(of: ProcOutput?.self) { group in
            group.addTask { try await Proc.run(bin, args) }
            group.addTask { try await Task.sleep(for: timeout); return nil }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
        try Task.checkCancellation()
        guard let result else { throw DockerUnavailable.notResponding }
        if !result.ok, DockerParse.isDaemonDown(result.err) { throw DockerUnavailable.notRunning }
        return result
    }

    /// stdout of a read that must succeed.
    static func read(_ args: [String], timeout: Duration = readTimeout) async throws -> String {
        let r = try await run(args, timeout: timeout)
        guard r.ok else { throw AppError.shell(failure(r, "docker \(args.prefix(2).joined(separator: " "))")) }
        return r.out
    }

    static func failure(_ r: ProcOutput, _ what: String) -> String {
        let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Error response from daemon: ", with: "")
        return msg.isEmpty ? "\(what) failed (exit \(r.status))" : msg
    }

    // MARK: - Load

    /// Everything but the slow per-volume / per-container sizes (see `measure`).
    /// Throws `DockerUnavailable` when Docker isn't running or answering.
    public static func load() async throws -> DockerSnapshot {
        // `df` first: if the daemon is down it fails fast, before fanning out.
        let usage = DockerParse.usage(try await read(["system", "df", "--format", "{{json .}}"]))
        async let imagesOut = read(["images", "--format", "{{json .}}"])
        // `--size=false`: `{{json .}}` would otherwise compute every container's size (slow).
        async let psOut = read(["ps", "-a", "--size=false", "--format", "{{json .}}"])
        async let volumesOut = read(["volume", "ls", "--format", "{{json .}}"])
        async let danglingOut = read(["volume", "ls", "-q", "-f", "dangling=true"])
        async let contextOut = try? read(["context", "show"])

        let containers = DockerParse.containers(try await psOut)
        let imageIDs = await containerImageIDs(containers.map(\.id))
        let images = DockerParse.markInUse(DockerParse.images(try await imagesOut),
                                           containers: containers, containerImageIDs: imageIDs)
        let volumes = DockerParse.volumes(try await volumesOut, dangling: DockerParse.names(try await danglingOut))
        let context = await contextOut?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DockerSnapshot(usage: usage, images: images, containers: containers, volumes: volumes,
                              context: context?.isEmpty == false ? context : nil)
    }

    /// Full image ids behind every container — exact "in use" even when a
    /// container shows an old tag. Best-effort: name matching covers a failure.
    static func containerImageIDs(_ ids: [String]) async -> Set<String> {
        let ids = ids.filter(DockerValidate.isHexID)
        guard !ids.isEmpty,
              let out = try? await read(["container", "inspect", "--format", "{{.Image}}"] + ids) else { return [] }
        return DockerParse.names(out)
    }

    /// `docker system df -v`: per-volume and per-container sizes, and exact
    /// image usage counts. Slow (walks volumes); nil when it fails.
    public static func measure() async -> DockerSizes? {
        guard let out = try? await read(["system", "df", "-v", "--format", "{{json .}}"], timeout: measureTimeout)
        else { return nil }
        return DockerParse.verbose(out)
    }

    /// Fold `measure()` results into a snapshot. `usage: false` carries only
    /// sizes over (for a fresh load shown before its own measure finishes).
    public static func apply(_ sizes: DockerSizes, to snap: DockerSnapshot, usage: Bool = true) -> DockerSnapshot {
        var s = snap
        for i in s.volumes.indices { s.volumes[i].bytes = sizes.volumes[s.volumes[i].name] }
        for i in s.containers.indices { s.containers[i].bytes = sizes.containers[s.containers[i].id] }
        for i in s.images.indices {
            let id = s.images[i].imageID
            s.images[i].uniqueBytes = sizes.imageUnique[id]
            if usage, let n = sizes.imageContainers[id], n > 0 { s.images[i].inUse = true }
        }
        return s
    }
}
