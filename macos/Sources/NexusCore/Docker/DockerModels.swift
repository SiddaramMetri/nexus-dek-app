import Foundation

/// The four rows of `docker system df`.
public enum DockerUsageKind: String, Sendable, CaseIterable, Identifiable {
    case images, containers, volumes, buildCache
    public var id: String { rawValue }

    /// `Type` as `docker system df` prints it.
    var dfType: String {
        switch self {
        case .images: "Images"
        case .containers: "Containers"
        case .volumes: "Local Volumes"
        case .buildCache: "Build Cache"
        }
    }

    public var label: String {
        switch self {
        case .images: "Images"
        case .containers: "Containers"
        case .volumes: "Volumes"
        case .buildCache: "Build cache"
        }
    }
}

/// One `docker system df` row: total and reclaimable size for a type.
public struct DockerUsage: Equatable, Sendable {
    public let kind: DockerUsageKind
    public let total: Int
    public let active: Int
    public let bytes: UInt64
    public let reclaimable: UInt64
}

public struct DockerImage: Identifiable, Equatable, Sendable {
    /// One row per repo:tag, so an image tagged twice shows twice.
    public var id: String { "\(imageID)|\(repository):\(tag)" }
    /// Short hex id as `docker images` prints it.
    public let imageID: String
    public let repository: String
    public let tag: String
    public let bytes: UInt64?
    public let created: Date?
    public let createdSince: String
    /// Some container (running or stopped) was created from it.
    public var inUse: Bool
    /// Bytes only this image holds (not shared with other images); from `system df -v`.
    public var uniqueBytes: UInt64?

    /// Untagged image: what `docker image prune` removes.
    public var isDangling: Bool { repository == "<none>" && tag == "<none>" }
    public var removable: Bool { !inUse }

    public var reference: String {
        if isDangling { return "<none>" }
        return tag == "<none>" ? repository : "\(repository):\(tag)"
    }

    /// What `docker image rm` gets: the tag for a tagged row (untags; deletes on
    /// the last tag), the id for an untagged one.
    public var removeArg: String { tag == "<none>" ? imageID : "\(repository):\(tag)" }

    /// What removing it frees, as far as we know.
    public var freeableBytes: UInt64? { uniqueBytes ?? bytes }
}

public struct DockerContainer: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let image: String
    /// running · exited · created · paused · restarting · dead · removing
    public let state: String
    /// "Exited (0) 3 days ago", "Up 2 hours"
    public let status: String
    public let created: Date?
    /// Writable layer size; from `system df -v`, nil until measured.
    public var bytes: UInt64?

    /// Only stopped containers may be removed; running/paused/restarting are locked.
    public var removable: Bool { ["exited", "created", "dead"].contains(state) }
    public var isRunning: Bool { !removable }
}

public struct DockerVolume: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let driver: String
    public let labels: String
    /// No container (running or stopped) references it.
    public let dangling: Bool
    /// From `system df -v`, nil until measured.
    public var bytes: UInt64?

    public var removable: Bool { dangling }
    /// A 64-hex name: created by an image's VOLUME, not named by anyone.
    public var isAnonymous: Bool { DockerValidate.isHexID(name) && name.count == 64 }
    /// `com.docker.compose.project` label, when compose made it.
    public var composeProject: String? { DockerParse.label("com.docker.compose.project", in: labels) }
}

/// Everything the Docker tab shows, read in one pass.
public struct DockerSnapshot: Equatable, Sendable {
    public var usage: [DockerUsage]
    public var images: [DockerImage]
    public var containers: [DockerContainer]
    public var volumes: [DockerVolume]
    /// `docker context show` ("colima", "desktop-linux"); nil if unknown.
    public var context: String?

    public init(usage: [DockerUsage], images: [DockerImage], containers: [DockerContainer],
                volumes: [DockerVolume], context: String? = nil) {
        self.usage = usage
        self.images = images
        self.containers = containers
        self.volumes = volumes
        self.context = context
    }

    public func usage(_ kind: DockerUsageKind) -> DockerUsage? { usage.first { $0.kind == kind } }
    public var totalBytes: UInt64 { usage.map(\.bytes).reduce(0, +) }
    public var reclaimableBytes: UInt64 { usage.map(\.reclaimable).reduce(0, +) }

    public var danglingImages: [DockerImage] { images.filter { $0.isDangling && !$0.inUse } }
    public var stoppedContainers: [DockerContainer] { containers.filter(\.removable) }
    public var unusedVolumes: [DockerVolume] { volumes.filter(\.dangling) }
    /// What `docker volume prune` (Docker 23+) takes: unused anonymous volumes.
    public var prunableVolumes: [DockerVolume] { unusedVolumes.filter(\.isAnonymous) }
}

/// Sizes that only `docker system df -v` knows (it's slow: it walks volumes).
public struct DockerSizes: Equatable, Sendable {
    public var volumes: [String: UInt64] = [:]
    /// Volume name → number of containers using it.
    public var volumeLinks: [String: Int] = [:]
    /// Container short id → writable layer bytes.
    public var containers: [String: UInt64] = [:]
    /// Image short id → bytes not shared with any other image.
    public var imageUnique: [String: UInt64] = [:]
    /// Image short id → number of containers created from it.
    public var imageContainers: [String: Int] = [:]
}

/// Why the tab can't show anything. Calm states, not failures.
public enum DockerUnavailable: Error, Equatable, Sendable, LocalizedError {
    case notInstalled
    /// The daemon / Colima VM isn't up — the socket refused or doesn't exist.
    case notRunning
    /// The daemon accepted the connection but didn't answer in time.
    case notResponding

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "Docker isn't installed."
        case .notRunning: "Docker isn't running."
        case .notResponding: "Docker isn't responding."
        }
    }
}
