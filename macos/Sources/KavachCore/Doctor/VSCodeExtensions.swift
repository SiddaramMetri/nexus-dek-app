import Foundation

/// One installed extension, from a static package.json scan (never spawns the
/// `code` CLI to read).
struct ExtMeta: Equatable {
    var id: String
    var display: String
    var publisher: String
    var star: Bool
    var startup: Bool
}

struct ExtAudit: Equatable {
    var total: Int
    var star: [String]
    var startup: Int
    var ai: [String]
    var dups: [String]
}

enum VSCodeExtensions {
    static let auditId = "extension_audit"

    /// One assistant per publisher counts once (copilot + copilot-chat = one).
    static let aiKeywords = ["copilot", "claude", "continue", "codeium", "tabnine", "chatgpt", "cline", "cody", "amazon-q"]
    static let maxNamed = 8

    /// VSCode's own CLI — the sanctioned uninstall path (no internals touched).
    static let codeCLI = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"

    static func available() -> Bool { ArchiverFS.isDir(Paths.vscodeExtensions) }

    static var cliAvailable: Bool { ArchiverFS.isFile(URL(fileURLWithPath: codeCLI)) }

    /// "auto-rename-tag" → "Auto Rename Tag" (fallback when no displayName).
    static func titleCase(_ name: String) -> String {
        name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// `nls` is the optional package.nls.json for resolving "%key%" display names.
    static func parseManifest(_ raw: String, nls: String?) -> ExtMeta? {
        guard let v = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let name = (v["name"] as? String)?.lowercased(),
              let publisher = (v["publisher"] as? String)?.lowercased() else { return nil }
        let events = (v["activationEvents"] as? [Any])?.compactMap { $0 as? String } ?? []
        var display: String?
        if let dn = v["displayName"] as? String {
            if dn.count >= 2, dn.hasPrefix("%"), dn.hasSuffix("%") {
                // Localized: look the key up in package.nls.json.
                let key = String(dn.dropFirst().dropLast())
                let table = nls.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
                display = table?[key] as? String
            } else {
                display = dn
            }
        }
        return ExtMeta(id: "\(publisher).\(name)", display: display ?? titleCase(name), publisher: publisher,
                       star: events.contains("*"), startup: events.contains("onStartupFinished"))
    }

    static func audit(_ metas: [ExtMeta]) -> ExtAudit {
        var seen: [String: Int] = [:]
        var aiByPublisher: [String: String] = [:]
        for m in metas {
            seen[m.id, default: 0] += 1
            if aiKeywords.contains(where: { m.id.contains($0) }), aiByPublisher[m.publisher] == nil {
                aiByPublisher[m.publisher] = m.id
            }
        }
        return ExtAudit(
            total: metas.count,
            star: Array(Set(metas.filter(\.star).map(\.id))).sorted(),
            startup: metas.filter(\.startup).count,
            ai: aiByPublisher.values.sorted(),
            dups: seen.filter { $0.value > 1 }.map(\.key).sorted())
    }

    /// Every installed extension (also the validation set for uninstalls).
    static func installed(root: URL = Paths.vscodeExtensions) -> [ExtMeta] {
        (ArchiverFS.entries(root) ?? [])
            .filter { ArchiverFS.isDir($0) && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { dir in
                guard let raw = try? String(contentsOf: dir.appendingPathComponent("package.json"), encoding: .utf8)
                else { return nil }
                let nls = try? String(contentsOf: dir.appendingPathComponent("package.nls.json"), encoding: .utf8)
                return parseManifest(raw, nls: nls)
            }
    }

    static func activationLabel(_ m: ExtMeta) -> String {
        m.star ? "always-on (*)" : m.startup ? "activates at startup" : "loads on demand"
    }

    static func run() -> [Finding] {
        let metas = installed()
        return metas.isEmpty ? [] : findings(metas, canUninstall: cliAvailable)
    }

    /// Aggregate line + one row per extension (uninstallable via VSCode's CLI).
    static func findings(_ metas: [ExtMeta], canUninstall: Bool) -> [Finding] {
        let a = audit(metas)
        var parts: [String] = []
        if !a.star.isEmpty {
            parts.append("Always-on (`*` activation — the worst kind): \(a.star.joined(separator: ", ")).")
        }
        if a.ai.count > 1 {
            parts.append("AI assistants stacked: \(a.ai.prefix(maxNamed).joined(separator: ", ")) — each one indexes "
                + "your workspace and runs its own processes; keep one.")
        }
        if !a.dups.isEmpty { parts.append("Installed more than once: \(a.dups.joined(separator: ", ")).") }
        parts.append("Ground truth is GUI-only: run \"Developer: Startup Performance\" inside VSCode.")

        let issues = !a.star.isEmpty || a.ai.count > 1 || !a.dups.isEmpty
        var out = [Finding(
            probeId: auditId, scope: .vscode, severity: issues ? .yellow : .green, tag: .speed,
            summary: "\(a.total) extensions · \(a.startup) activate at startup · \(a.ai.count) AI assistant"
                + (a.ai.count == 1 ? "" : "s"),
            explain: parts.joined(separator: " "),
            guide: issues ? [
                "In VSCode: Extensions panel → disable what you don't use (\"Disable (Workspace)\" keeps it "
                    + "available elsewhere)",
                "Run \"Developer: Show Running Extensions\" for live per-extension cost",
            ] : nil)]

        var seen = Set<String>()
        for m in metas where seen.insert(m.id).inserted { // multi-version duplicates listed once
            out.append(Finding(
                probeId: auditId, scope: .vscode, severity: m.star ? .yellow : .green, tag: .speed,
                summary: "\(m.display) · \(activationLabel(m))",
                explain: "\(m.id) — uninstalling runs VSCode's own CLI (`code --uninstall-extension`); your settings "
                    + "survive and it can be reinstalled from the Marketplace anytime (a running VSCode applies the "
                    + "change after a restart). A persistent disable-only isn't safely automatable from outside "
                    + "VSCode — use its Extensions panel for that.",
                fix: canUninstall ? "vscode_ext_rm:\(m.id)" : nil))
        }
        return out
    }

    /// Native-confirm copy for an extension uninstall.
    static func confirmation(_ id: String) -> (title: String, message: String) {
        ("Uninstall \(id)?",
         "Runs VSCode's own CLI. Settings survive; reinstall anytime from the Marketplace. "
             + "A running VSCode applies the change after a restart.")
    }

    /// `code --uninstall-extension`, validated against the ACTUAL installed set
    /// first — the UI's string is never trusted.
    static func uninstall(_ id: String, journal: ArchiverFS.JournalSink = ArchiverFS.liveJournal) async throws -> String {
        guard installed().contains(where: { $0.id == id }) else { throw AppError.notFound("no such extension: \(id)") }
        guard cliAvailable else { throw AppError.notFound("VSCode CLI not found in the app bundle") }
        let out: ProcOutput
        do { out = try await Proc.run(codeCLI, ["--uninstall-extension", id]) } catch {
            throw AppError.shell("code CLI: \(AppError.from(error).message)")
        }
        guard out.ok else { throw AppError.shell(out.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
        journal("vscodeExtUninstall", ["extension": id])
        return "Uninstalled \(id) — restart VSCode to apply; reinstall anytime from the Marketplace"
    }
}
