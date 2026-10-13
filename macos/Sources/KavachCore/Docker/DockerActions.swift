import Foundation

/// Outcome of a removal or prune, measured after the fact.
public struct DockerResult: Sendable {
    /// How many of the targets are gone (for a prune: how many fewer there are).
    public let removed: Int
    /// What docker refused, one message per line of stderr.
    public let failures: [String]
    /// From the prune's own "Total reclaimed space", else the `system df` drop; nil if unknown.
    public let freedBytes: UInt64?
    /// State after the change; nil if re-reading failed.
    public let snapshot: DockerSnapshot?
}

/// The one-click cleanups. Deliberately no `system prune -a --volumes`.
public enum DockerPrune: String, CaseIterable, Sendable, Identifiable {
    case danglingImages, stoppedContainers, buildCache, unusedVolumes
    public var id: String { rawValue }

    var args: [String] {
        switch self {
        case .danglingImages: ["image", "prune", "-f"]
        case .stoppedContainers: ["container", "prune", "-f"]
        case .buildCache: ["builder", "prune", "-f"]
        case .unusedVolumes: ["volume", "prune", "-f"]
        }
    }

    public var kind: DockerUsageKind {
        switch self {
        case .danglingImages: .images
        case .stoppedContainers: .containers
        case .buildCache: .buildCache
        case .unusedVolumes: .volumes
        }
    }

    public var title: String {
        switch self {
        case .danglingImages: "Remove dangling images"
        case .stoppedContainers: "Remove stopped containers"
        case .buildCache: "Clear build cache"
        case .unusedVolumes: "Remove unused volumes"
        }
    }

    /// What it would take right now: a count and, when known, bytes.
    public func plan(_ s: DockerSnapshot) -> (count: Int, bytes: UInt64?) {
        switch self {
        case .danglingImages:
            let list = s.danglingImages
            return (list.count, DockerActions.sum(list.map(\.freeableBytes)))
        case .stoppedContainers:
            return (s.stoppedContainers.count, s.usage(.containers)?.reclaimable)
        case .buildCache:
            let u = s.usage(.buildCache)
            return (u?.total ?? 0, u?.reclaimable)
        case .unusedVolumes:
            let list = s.prunableVolumes
            return (list.count, DockerActions.sum(list.map(\.bytes)))
        }
    }

    /// Title, message and button for the native confirm — states what goes and how much.
    public func confirmText(_ s: DockerSnapshot) -> (title: String, message: String, action: String) {
        let (n, bytes) = plan(s)
        let about = bytes.map { " — about \(Format.bytes($0))" } ?? ""
        switch self {
        case .danglingImages:
            return ("Remove dangling images?",
                    "Deletes \(DockerActions.plural(n, "untagged image")) (shown as <none>) that no container uses\(about). "
                        + "Tagged images stay.",
                    "Remove images")
        case .stoppedContainers:
            return ("Remove stopped containers?",
                    "Deletes all \(DockerActions.plural(n, "stopped container"))\(about), with their logs and any files "
                        + "written inside them. Running containers, images and volumes stay.",
                    "Remove containers")
        case .buildCache:
            return ("Clear build cache?",
                    "Deletes Docker's unused build cache — up to \(Format.bytes(bytes ?? 0)). "
                        + "Your next builds rebuild those layers, so they'll be slower once.",
                    "Clear cache")
        case .unusedVolumes:
            return ("Permanently delete unused volumes?",
                    "Deletes \(DockerActions.plural(n, "anonymous volume")) that no container uses\(about).\n\n"
                        + "Volumes can hold database data (Postgres, MySQL, Redis…). There's no Trash and no undo. "
                        + "Named volumes are kept by Docker 23 and later — remove those one by one from the Volumes list.",
                    "Delete volumes")
        }
    }
}

/// Removals. Only unused things are ever passed on: in-use images, running
/// containers and attached volumes are refused here, and docker refuses them
/// again (no `-f`, ever).
public enum DockerActions {
    public static func removeImages(_ images: [DockerImage], confirmer: Confirmer) async throws -> DockerResult {
        let targets = images.filter(\.removable)
        let bytes = sum(targets.map(\.freeableBytes))
        return try await remove(
            what: "images", kind: .images, verb: ["image", "rm"],
            args: targets.map(\.removeArg), labels: targets.map { $0.isDangling ? "<none> \($0.imageID)" : $0.reference },
            title: "Remove \(plural(targets.count, "image"))?",
            message: "\(list(targets.map { $0.isDangling ? "<none> (\($0.imageID))" : $0.reference }))\n\n"
                + "Frees up to \(Format.bytes(bytes ?? 0)) (layers shared with other images stay). "
                + "Docker can pull or rebuild them later.",
            action: "Remove", confirmer: confirmer,
            stillThere: { snap in targets.filter { t in snap.images.contains { $0.id == t.id } }.count })
    }

    public static func removeContainers(_ containers: [DockerContainer], confirmer: Confirmer) async throws -> DockerResult {
        let targets = containers.filter(\.removable)
        let size = sum(targets.map(\.bytes)).map { " Frees about \(Format.bytes($0))." } ?? ""
        return try await remove(
            what: "containers", kind: .containers, verb: ["rm"],
            args: targets.map(\.id), labels: targets.map(\.name),
            title: "Remove \(plural(targets.count, "stopped container"))?",
            message: "\(list(targets.map(\.name)))\n\nTheir logs and any files written inside them go too; "
                + "images and volumes stay.\(size)",
            action: "Remove", confirmer: confirmer,
            stillThere: { snap in targets.filter { t in snap.containers.contains { $0.id == t.id } }.count })
    }

    public static func removeVolumes(_ volumes: [DockerVolume], confirmer: Confirmer) async throws -> DockerResult {
        let targets = volumes.filter(\.removable)
        let size = sum(targets.map(\.bytes)).map { "\n\nFrees about \(Format.bytes($0))." } ?? ""
        return try await remove(
            what: "volumes", kind: .volumes, verb: ["volume", "rm"],
            args: targets.map(\.name), labels: targets.map(\.name),
            title: "Permanently delete \(plural(targets.count, "volume"))?",
            message: "Volumes can hold database data (Postgres, MySQL, Redis…). These are deleted for good — "
                + "there's no Trash and no undo:\n\n\(list(targets.map(\.name)))\(size)",
            action: "Delete \(plural(targets.count, "volume"))", confirmer: confirmer,
            stillThere: { snap in targets.filter { t in snap.volumes.contains { $0.name == t.name } }.count })
    }

    public static func prune(_ p: DockerPrune, current: DockerSnapshot, confirmer: Confirmer) async throws -> DockerResult {
        let text = p.confirmText(current)
        try await confirmer.require(title: text.title, message: text.message, action: text.action, destructive: true)
        let before = await freshUsage(p.kind) ?? current.usage(p.kind)
        let r = try await DockerCleaner.run(p.args, timeout: DockerCleaner.writeTimeout)
        guard r.ok else { throw AppError.shell(DockerCleaner.failure(r, "docker \(p.args.prefix(2).joined(separator: " "))")) }
        let after = try? await DockerCleaner.load()
        let removed = max(0, (before?.total ?? 0) - (after?.usage(p.kind)?.total ?? before?.total ?? 0))
        let freed = DockerParse.reclaimed(r.out) ?? drop(before, after?.usage(p.kind))
        journal("prune:\(p.rawValue)", removed: removed, freed: freed, targets: [])
        return DockerResult(removed: removed, failures: [], freedBytes: freed, snapshot: after)
    }

    // MARK: - Shared

    static func remove(what: String, kind: DockerUsageKind, verb: [String], args: [String], labels: [String],
                       title: String, message: String, action: String, confirmer: Confirmer,
                       stillThere: (DockerSnapshot) -> Int) async throws -> DockerResult {
        guard !args.isEmpty else { throw AppError.forbidden("Nothing removable is selected — only unused items can go.") }
        for a in args { try DockerValidate.target(a) }
        try await confirmer.require(title: title, message: message, action: action, destructive: true)
        let before = await freshUsage(kind)
        let r = try await DockerCleaner.run(verb + args, timeout: DockerCleaner.writeTimeout)
        let failures = r.err.split(whereSeparator: \.isNewline)
            .map { $0.replacingOccurrences(of: "Error response from daemon: ", with: "") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let after = try? await DockerCleaner.load()
        // Re-read instead of trusting the exit code: docker removes what it can.
        let removed = after.map { args.count - stillThere($0) } ?? (r.ok ? args.count : 0)
        guard removed > 0 else {
            throw AppError.shell(failures.first ?? DockerCleaner.failure(r, "docker \(verb.joined(separator: " "))"))
        }
        let freed = drop(before, after?.usage(kind))
        journal(what, removed: removed, freed: freed, targets: labels)
        return DockerResult(removed: removed, failures: failures, freedBytes: freed, snapshot: after)
    }

    static func freshUsage(_ kind: DockerUsageKind) async -> DockerUsage? {
        guard let out = try? await DockerCleaner.read(["system", "df", "--format", "{{json .}}"]) else { return nil }
        return DockerParse.usage(out).first { $0.kind == kind }
    }

    /// Bytes a type shrank by; nil when either side is unknown.
    static func drop(_ before: DockerUsage?, _ after: DockerUsage?) -> UInt64? {
        guard let b = before?.bytes, let a = after?.bytes else { return nil }
        return b > a ? b - a : 0
    }

    static func journal(_ what: String, removed: Int, freed: UInt64?, targets: [String]) {
        var fields: [String: Any] = ["what": what, "count": removed]
        if let freed { fields["freedBytes"] = freed }
        if !targets.isEmpty {
            fields["targets"] = targets.prefix(20).joined(separator: ", ") + (targets.count > 20 ? " +\(targets.count - 20) more" : "")
        }
        Journal.write(action: "dockerPrune", fields)
    }

    /// nil when nothing is known; otherwise the sum of the known sizes.
    public static func sum(_ sizes: [UInt64?]) -> UInt64? {
        let known = sizes.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    public static func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// Up to eight names, one per line, then "and N more".
    static func list(_ names: [String]) -> String {
        let shown = names.prefix(8).map { "• \($0)" }.joined(separator: "\n")
        return names.count > 8 ? shown + "\n…and \(names.count - 8) more" : shown
    }
}
