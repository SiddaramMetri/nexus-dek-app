import Foundation

/// Unsaved-work check for a repository before cleaning it. Removing
/// node_modules never touches code, but a project with uncommitted changes or
/// unpushed commits is worth a second look before anything is trashed.
public enum GitSafety {
    public struct Status: Equatable, Sendable {
        public var branch: String?
        /// Modified, staged or untracked entries.
        public var changed: Int
        /// Commits not on the upstream branch.
        public var ahead: Int
        /// The branch has commits but no upstream to push to.
        public var noUpstream: Bool

        public var hasUnsavedWork: Bool { changed > 0 || ahead > 0 }

        /// "5 uncommitted changes · 2 unpushed commits"
        public var summary: String {
            var parts: [String] = []
            if changed > 0 { parts.append("\(changed) uncommitted change\(changed == 1 ? "" : "s")") }
            if ahead > 0 { parts.append("\(ahead) unpushed commit\(ahead == 1 ? "" : "s")") }
            if parts.isEmpty { parts.append(noUpstream ? "no remote branch" : "clean") }
            return parts.joined(separator: " · ")
        }
    }

    /// A real git binary — never `/usr/bin/git`, whose stub pops Apple's
    /// "install command line developer tools" dialog on Macs without them.
    static var gitPath: String? {
        ["/Library/Developer/CommandLineTools/usr/bin/git",
         "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
         "/opt/homebrew/bin/git", "/usr/local/bin/git"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// nil when `root` isn't a git repo, git isn't available, or git fails.
    /// Read-only (`status` never writes; no fetch, no network).
    public static func status(_ root: String) async -> Status? {
        guard FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(".git")),
              let git = gitPath,
              let out = try? await Proc.run(git, ["-C", root, "status", "--porcelain=v1", "--branch", "--untracked-files=normal"],
                                            env: ["GIT_OPTIONAL_LOCKS": "0"]),
              out.ok else { return nil }
        return parse(out.out)
    }

    /// `## main...origin/main [ahead 2, behind 1]` + one line per changed entry.
    static func parse(_ porcelain: String) -> Status {
        var status = Status(branch: nil, changed: 0, ahead: 0, noUpstream: false)
        for line in porcelain.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("## ") else { status.changed += 1; continue }
            let head = line.dropFirst(3)
            let branchPart = head.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if branchPart.hasPrefix("No commits yet on ") || head.hasPrefix("No commits yet on ") {
                status.branch = String(head.dropFirst("No commits yet on ".count))
                continue
            }
            if let dots = branchPart.range(of: "...") {
                status.branch = String(branchPart[..<dots.lowerBound])
            } else {
                status.branch = branchPart
                status.noUpstream = branchPart != "HEAD"
            }
            if let r = head.range(of: "ahead ") {
                let digits = head[r.upperBound...].prefix { $0.isNumber }
                status.ahead = Int(digits) ?? 0
            }
        }
        return status
    }

    /// Statuses for several repos, a few at a time.
    public static func statuses(_ roots: [String]) async -> [String: Status] {
        var result: [String: Status] = [:]
        await withTaskGroup(of: (String, Status?).self) { group in
            var it = roots.makeIterator()
            for _ in 0..<4 { if let r = it.next() { group.addTask { (r, await status(r)) } } }
            for await (root, s) in group {
                if let s { result[root] = s }
                if let r = it.next() { group.addTask { (r, await status(r)) } }
            }
        }
        return result
    }
}
