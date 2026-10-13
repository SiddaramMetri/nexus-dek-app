import Foundation

/// Parsers for docker CLI output. Every listing is read with
/// `--format '{{json .}}'`: one JSON object per line, every value a string.
public enum DockerParse {
    // MARK: - Sizes

    /// "1.23GB" · "512MB" · "1.09kB" · "0B" · "1.2GB (45%)" · "0B (virtual 432MB)" → bytes.
    /// Docker prints decimal units (go-units `HumanSize`); KiB/MiB/GiB are binary.
    /// nil for "N/A", empty or anything unreadable.
    public static func bytes(_ raw: String) -> UInt64? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let paren = s.range(of: " (") { s = String(s[..<paren.lowerBound]) }
        s = s.replacingOccurrences(of: " ", with: "")
        let split = s.firstIndex { !($0.isNumber || $0 == "." || $0 == "e" || $0 == "+") } ?? s.endIndex
        guard let value = Double(s[..<split]), value >= 0, value.isFinite else { return nil }
        let unit = s[split...].lowercased()
        let mult: Double
        switch unit {
        case "", "b": mult = 1
        case "k", "kb": mult = 1e3
        case "m", "mb": mult = 1e6
        case "g", "gb": mult = 1e9
        case "t", "tb": mult = 1e12
        case "p", "pb": mult = 1e15
        case "kib": mult = 1024
        case "mib": mult = 1_048_576
        case "gib": mult = 1_073_741_824
        case "tib": mult = 1_099_511_627_776
        default: return nil
        }
        return UInt64((value * mult).rounded())
    }

    // MARK: - JSON lines

    /// One dictionary per `{…}` line; values coerced to strings. Junk lines are skipped.
    public static func jsonLines(_ out: String) -> [[String: String]] {
        out.split(whereSeparator: \.isNewline).compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{") else { return nil }
            return object(Data(t.utf8)).map(strings)
        }
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func strings(_ obj: [String: Any]) -> [String: String] {
        obj.mapValues { v in
            switch v {
            case let s as String: s
            case let n as NSNumber: n.stringValue
            default: String(describing: v)
            }
        }
    }

    /// `-q` output: one id or name per line.
    public static func names(_ out: String) -> Set<String> {
        Set(out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    // MARK: - Commands

    /// `docker system df --format '{{json .}}'`
    public static func usage(_ out: String) -> [DockerUsage] {
        jsonLines(out).compactMap { r in
            guard let kind = DockerUsageKind.allCases.first(where: { $0.dfType == r["Type"] }) else { return nil }
            return DockerUsage(kind: kind, total: Int(r["TotalCount"] ?? "") ?? 0, active: Int(r["Active"] ?? "") ?? 0,
                               bytes: bytes(r["Size"] ?? "") ?? 0, reclaimable: bytes(r["Reclaimable"] ?? "") ?? 0)
        }
    }

    /// `docker images --format '{{json .}}'` — `inUse` is filled by `markInUse`.
    public static func images(_ out: String) -> [DockerImage] {
        jsonLines(out).compactMap { r in
            guard let id = r["ID"].map(shortID), !id.isEmpty else { return nil }
            return DockerImage(imageID: id, repository: r["Repository"] ?? "<none>", tag: r["Tag"] ?? "<none>",
                               bytes: bytes(r["Size"] ?? ""), created: date(r["CreatedAt"] ?? ""),
                               createdSince: r["CreatedSince"] ?? "", inUse: false)
        }
    }

    /// `docker ps -a --format '{{json .}}'`
    public static func containers(_ out: String) -> [DockerContainer] {
        jsonLines(out).compactMap { r in
            guard let id = r["ID"].map(shortID), !id.isEmpty else { return nil }
            let status = r["Status"] ?? ""
            let state = (r["State"]).flatMap { $0.isEmpty ? nil : $0.lowercased() } ?? stateFromStatus(status)
            let name = (r["Names"] ?? "").split(separator: ",").first.map(String.init) ?? id
            return DockerContainer(id: id, name: name, image: r["Image"] ?? "", state: state, status: status,
                                   created: date(r["CreatedAt"] ?? ""), bytes: nil)
        }
    }

    /// `docker volume ls --format '{{json .}}'` plus the `-f dangling=true -q` names.
    public static func volumes(_ out: String, dangling: Set<String>) -> [DockerVolume] {
        jsonLines(out).compactMap { r in
            guard let name = r["Name"], !name.isEmpty else { return nil }
            return DockerVolume(name: name, driver: r["Driver"] ?? "local", labels: r["Labels"] ?? "",
                                dangling: dangling.contains(name), bytes: nil)
        }
    }

    /// `docker system df -v --format '{{json .}}'`: a single object with
    /// `Images`, `Containers`, `Volumes` and `BuildCache` arrays.
    public static func verbose(_ out: String) -> DockerSizes? {
        guard let obj = object(Data(out.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) else { return nil }
        let rows = { (key: String) in ((obj[key] as? [[String: Any]]) ?? []).map(strings) }
        var s = DockerSizes()
        for v in rows("Volumes") {
            guard let name = v["Name"] else { continue }
            if let b = bytes(v["Size"] ?? "") { s.volumes[name] = b }
            if let n = Int(v["Links"] ?? "") { s.volumeLinks[name] = n }
        }
        for c in rows("Containers") {
            guard let id = c["ID"].map(shortID), let b = bytes(c["Size"] ?? "") else { continue }
            s.containers[id] = b
        }
        for i in rows("Images") {
            guard let id = i["ID"].map(shortID) else { continue }
            if let b = bytes(i["UniqueSize"] ?? "") { s.imageUnique[id] = b }
            if let n = Int(i["Containers"] ?? "") { s.imageContainers[id] = n }
        }
        return s
    }

    /// "Total reclaimed space: 1.2GB" from any `prune`.
    public static func reclaimed(_ out: String) -> UInt64? {
        guard let line = out.split(whereSeparator: \.isNewline).last(where: { $0.contains("reclaimed space:") }),
              let colon = line.lastIndex(of: ":") else { return nil }
        return bytes(String(line[line.index(after: colon)...]))
    }

    /// The CLI couldn't reach the daemon (socket missing or refusing) — Docker isn't running.
    public static func isDaemonDown(_ stderr: String) -> Bool {
        let e = stderr.lowercased()
        return e.contains("cannot connect to the docker daemon") || e.contains("failed to connect to the docker api")
            || e.contains("is the docker daemon running") || e.contains("error during connect")
            || (e.contains("docker.sock") && (e.contains("no such file") || e.contains("connection refused")))
    }

    // MARK: - Classification

    /// Marks every image some container was created from. `containerImageIDs`
    /// are the full `sha256:` ids from `docker container inspect` (best-effort;
    /// the `Image` name each container shows is matched too).
    public static func markInUse(_ images: [DockerImage], containers: [DockerContainer],
                                 containerImageIDs: Set<String> = []) -> [DockerImage] {
        let ids = containerImageIDs.map(shortIDFull)
        let refs = containers.map(\.image)
        return images.map { img in
            var img = img
            img.inUse = ids.contains { $0.hasPrefix(img.imageID) } || refs.contains { refMatches($0, img) }
            return img
        }
    }

    /// Does a container's `Image` field ("postgres:16", "redis", "a1b2c3d4e5f6",
    /// "foo@sha256:…") name this image row?
    static func refMatches(_ ref: String, _ img: DockerImage) -> Bool {
        let bare = ref.hasPrefix("sha256:") ? String(ref.dropFirst(7)) : ref
        if DockerValidate.isHexID(bare) { return img.imageID.hasPrefix(bare) || bare.hasPrefix(img.imageID) }
        guard !img.isDangling else { return false }
        let r = normalize(ref)
        if let at = r.firstIndex(of: "@") { return normalize(img.repository) == String(r[..<at]) }
        let slash = r.lastIndex(of: "/") ?? r.startIndex
        let (repo, tag): (String, String)
        if let colon = r[slash...].lastIndex(of: ":") {
            (repo, tag) = (String(r[..<colon]), String(r[r.index(after: colon)...]))
        } else {
            (repo, tag) = (r, "latest")
        }
        return normalize(img.repository) == repo && img.tag == tag
    }

    /// `docker.io/library/postgres` and `postgres` are the same repository.
    static func normalize(_ s: String) -> String {
        for prefix in ["docker.io/library/", "index.docker.io/library/", "docker.io/", "index.docker.io/"]
        where s.hasPrefix(prefix) { return String(s.dropFirst(prefix.count)) }
        return s
    }

    // MARK: - Small helpers

    /// `sha256:abc…` or a full id → the 12-char short id the listings use.
    static func shortID(_ s: String) -> String { String(shortIDFull(s).prefix(12)) }
    static func shortIDFull(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("sha256:") ? String(t.dropFirst(7)) : t
    }

    static func stateFromStatus(_ status: String) -> String {
        let s = status.lowercased()
        if s.hasPrefix("up") { return s.contains("paused") ? "paused" : "running" }
        if s.hasPrefix("exited") { return "exited" }
        if s.hasPrefix("created") { return "created" }
        if s.hasPrefix("restarting") { return "restarting" }
        if s.hasPrefix("dead") { return "dead" }
        return s.isEmpty ? "unknown" : s
    }

    /// "2024-05-01 10:22:33 +0530 IST" → Date (the trailing zone name is dropped).
    public static func date(_ raw: String) -> Date? {
        let parts = raw.split(separator: " ")
        guard parts.count >= 3 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f.date(from: parts.prefix(3).joined(separator: " "))
    }

    /// `key=value` out of docker's comma-joined label string.
    static func label(_ key: String, in labels: String) -> String? {
        for pair in labels.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == key { return String(kv[1]) }
        }
        return nil
    }
}

/// Every id or name passed to docker goes through here. Defense in depth: args
/// are always an array, and a leading alphanumeric means nothing parses as a flag.
public enum DockerValidate {
    /// 12–64 lowercase hex chars (short or full id).
    public static func isHexID(_ s: String) -> Bool {
        (12...64).contains(s.utf8.count) && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// `^[a-zA-Z0-9][a-zA-Z0-9_.:/@-]*$`, at most 255 chars.
    public static func isName(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard let first = u.first, u.count <= 255, isAlnum(first) else { return false }
        return u.allSatisfy { isAlnum($0) || "_.:/@-".utf8.contains($0) }
    }

    public static func isValid(_ s: String) -> Bool { isHexID(s) || isName(s) }

    public static func target(_ s: String) throws {
        guard isValid(s) else { throw AppError.invalidName("invalid Docker id or name: \(s)") }
    }

    private static func isAlnum(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }
}
