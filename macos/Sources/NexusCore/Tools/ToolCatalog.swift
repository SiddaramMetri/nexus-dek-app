import Foundation

/// A tool the Tools tab knows how to find. Only the installed ones are shown.
public struct ToolSpec: Sendable {
    public let id: String
    public let name: String
    public let kind: ToolKind
    public let symbol: String
    /// CLI executable name (nil for apps).
    public let binary: String?
    public let versionArgs: [String]
    /// Extra env for the version call (e.g. Terraform's update ping off).
    public let versionEnv: [String: String]
    /// `.app` bundle names, first found wins.
    public let bundles: [String]
    /// Homebrew cask token, to tell a cask-installed app from a self-updating one.
    public let cask: String?
    public let releaseNotes: String?

    init(_ id: String, _ name: String, symbol: String, binary: String? = nil, versionArgs: [String] = ["--version"],
         versionEnv: [String: String] = [:], bundles: [String] = [], cask: String? = nil, notes: String? = nil) {
        self.id = id
        self.name = name
        kind = bundles.isEmpty ? .cli : .app
        self.symbol = symbol
        self.binary = binary ?? (bundles.isEmpty ? id : nil)
        self.versionArgs = versionArgs
        self.versionEnv = versionEnv
        self.bundles = bundles
        self.cask = cask
        releaseNotes = notes
    }
}

public enum ToolCatalog {
    /// Display order: AI CLIs, then languages/package managers, infra, then apps.
    public static let all: [ToolSpec] = [
        ToolSpec("claude", "Claude Code", symbol: "sparkle",
                 notes: "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md"),
        ToolSpec("codex", "Codex CLI", symbol: "chevron.left.forwardslash.chevron.right",
                 notes: "https://github.com/openai/codex/releases"),
        ToolSpec("gemini", "Gemini CLI", symbol: "sparkles",
                 notes: "https://github.com/google-gemini/gemini-cli/releases"),
        ToolSpec("gh", "GitHub CLI", symbol: "arrow.triangle.pull", notes: "https://github.com/cli/cli/releases"),
        ToolSpec("git", "Git", symbol: "arrow.triangle.branch",
                 notes: "https://github.com/git/git/tree/master/Documentation/RelNotes"),
        ToolSpec("node", "Node.js", symbol: "hexagon", notes: "https://nodejs.org/en/blog/release"),
        ToolSpec("npm", "npm", symbol: "shippingbox", notes: "https://github.com/npm/cli/releases"),
        ToolSpec("pnpm", "pnpm", symbol: "shippingbox", notes: "https://github.com/pnpm/pnpm/releases"),
        ToolSpec("yarn", "Yarn", symbol: "shippingbox", notes: "https://github.com/yarnpkg/berry/releases"),
        ToolSpec("bun", "Bun", symbol: "hare", notes: "https://bun.sh/blog"),
        ToolSpec("deno", "Deno", symbol: "lizard", notes: "https://github.com/denoland/deno/releases"),
        ToolSpec("python3", "Python 3", symbol: "chevron.left.forwardslash.chevron.right",
                 notes: "https://docs.python.org/3/whatsnew/changelog.html"),
        ToolSpec("uv", "uv", symbol: "bolt", notes: "https://github.com/astral-sh/uv/releases"),
        ToolSpec("pipx", "pipx", symbol: "shippingbox", notes: "https://github.com/pypa/pipx/releases"),
        ToolSpec("rust", "Rust", symbol: "gearshape.2", binary: "rustc",
                 notes: "https://blog.rust-lang.org/releases/"),
        ToolSpec("go", "Go", symbol: "chevron.left.forwardslash.chevron.right", versionArgs: ["version"],
                 notes: "https://go.dev/doc/devel/release"),
        ToolSpec("java", "Java", symbol: "cup.and.saucer", versionArgs: ["-version"],
                 notes: "https://openjdk.org/projects/jdk/"),
        ToolSpec("docker", "Docker CLI", symbol: "cube.box",
                 notes: "https://docs.docker.com/engine/release-notes/"),
        ToolSpec("colima", "Colima", symbol: "cube.transparent", notes: "https://github.com/abiosoft/colima/releases"),
        ToolSpec("podman", "Podman", symbol: "cube.transparent",
                 notes: "https://github.com/containers/podman/releases"),
        ToolSpec("kubectl", "kubectl", symbol: "helm", versionArgs: ["version", "--client"],
                 notes: "https://kubernetes.io/releases/"),
        ToolSpec("terraform", "Terraform", symbol: "square.stack.3d.up", versionArgs: ["version"],
                 versionEnv: ["CHECKPOINT_DISABLE": "1"], notes: "https://github.com/hashicorp/terraform/releases"),
        ToolSpec("aws", "AWS CLI", symbol: "cloud", notes: "https://github.com/aws/aws-cli/blob/v2/CHANGELOG.rst"),
        ToolSpec("brew", "Homebrew", symbol: "mug", notes: "https://github.com/Homebrew/brew/releases"),

        ToolSpec("vscode", "Visual Studio Code", symbol: "app", bundles: ["Visual Studio Code.app"],
                 cask: "visual-studio-code", notes: "https://code.visualstudio.com/updates"),
        ToolSpec("cursor", "Cursor", symbol: "app", bundles: ["Cursor.app"], cask: "cursor",
                 notes: "https://cursor.com/changelog"),
        ToolSpec("windsurf", "Windsurf", symbol: "app", bundles: ["Windsurf.app"], cask: "windsurf",
                 notes: "https://windsurf.com/changelog"),
        ToolSpec("zed", "Zed", symbol: "app", bundles: ["Zed.app"], cask: "zed",
                 notes: "https://zed.dev/releases/stable"),
        ToolSpec("docker-desktop", "Docker Desktop", symbol: "app", bundles: ["Docker.app"], cask: "docker-desktop",
                 notes: "https://docs.docker.com/desktop/release-notes/"),
        ToolSpec("iterm", "iTerm", symbol: "app", bundles: ["iTerm.app"], cask: "iterm2",
                 notes: "https://iterm2.com/news.html"),
        ToolSpec("warp", "Warp", symbol: "app", bundles: ["Warp.app"], cask: "warp",
                 notes: "https://docs.warp.dev/getting-started/changelog"),
        ToolSpec("ghostty", "Ghostty", symbol: "app", bundles: ["Ghostty.app"], cask: "ghostty",
                 notes: "https://ghostty.org/docs/install/release-notes"),
        ToolSpec("postman", "Postman", symbol: "app", bundles: ["Postman.app"], cask: "postman",
                 notes: "https://www.postman.com/release-notes/postman-app/"),
        ToolSpec("tableplus", "TablePlus", symbol: "app", bundles: ["TablePlus.app"], cask: "tableplus",
                 notes: "https://tableplus.com/blog"),
    ]

    public static func spec(_ id: String) -> ToolSpec? { all.first { $0.id == id } }
}
