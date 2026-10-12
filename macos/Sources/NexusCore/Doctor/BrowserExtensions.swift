import Foundation

// browser_extensions — mirrors the VSCode extension audit: read each
// extension's on-disk manifest, list it with a display name, and offer one
// safe action. There is NO safe CLI to uninstall/disable a browser extension
// from outside the browser (Chrome signs its own state), so the action just
// opens that extension's own page in the browser.
extension BrowserProbes {
    public static let extensions = Probe(id: "browser_extensions", scope: .browser,
                                         available: anyInstalled) { await runExtensions() }

    struct Ext: Equatable {
        var id: String
        var name: String
        /// A background page / service worker keeps a process alive when unused.
        var background: Bool
    }

    /// User-installed extensions across every profile, deduped by id.
    static func installedExtensions(of b: Browser) -> [Ext] {
        var seen = Set<String>()
        var out: [Ext] = []
        for profile in DoctorSupport.children(b.supportDir) {
            for idPath in DoctorSupport.children(profile.appendingPathComponent("Extensions")) {
                let id = idPath.lastPathComponent
                // Chrome's own scratch dir / dotfiles are not extensions.
                if id.hasPrefix(".") || id == "Temp" || !DoctorSupport.isDir(idPath) { continue }
                guard seen.insert(id).inserted else { continue } // same extension in another profile
                if let ext = readExtension(id: id, dir: idPath) { out.append(ext) }
            }
        }
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// <Extensions>/<id>/<version>/manifest.json → display name + background.
    /// No readable manifest → nil (the extension is simply not listed).
    static func readExtension(id: String, dir: URL) -> Ext? {
        guard let vdir = DoctorSupport.children(dir).first(where: {
            DoctorSupport.isFile($0.appendingPathComponent("manifest.json"))
        }),
            let raw = try? String(contentsOf: vdir.appendingPathComponent("manifest.json"), encoding: .utf8),
            let parsed = parseExtManifest(raw, vdir: vdir) else { return nil }
        return Ext(id: id, name: parsed.0, background: parsed.1)
    }

    /// Static manifest parse → (display name, has-background). `vdir` is only
    /// read when the name is a `__MSG_key__` placeholder needing locale resolution.
    static func parseExtManifest(_ raw: String, vdir: URL) -> (String, Bool)? {
        guard let v = DoctorSupport.jsonObject(raw), let rawName = v["name"] as? String else { return nil }
        return (resolveName(rawName, manifest: v, vdir: vdir), v["background"] != nil)
    }

    /// `__MSG_extName__` → the localized string from _locales/<locale>/messages.json;
    /// anything else is already the name. Falls back to the raw name if unresolved.
    static func resolveName(_ rawName: String, manifest: [String: Any], vdir: URL) -> String {
        guard rawName.hasPrefix("__MSG_"), rawName.hasSuffix("__"), rawName.count >= 8 else { return rawName }
        let key = String(rawName.dropFirst(6).dropLast(2))
        let locale = manifest["default_locale"] as? String ?? "en"
        let msgs = vdir.appendingPathComponent("_locales/\(locale)/messages.json")
        return lookupMessage((try? String(contentsOf: msgs, encoding: .utf8)) ?? "", key: key) ?? rawName
    }

    /// messages.json → messages[key].message (Chrome i18n keys are case-insensitive).
    static func lookupMessage(_ raw: String, key: String) -> String? {
        guard let v = DoctorSupport.jsonObject(raw) else { return nil }
        let entry = v[key] ?? v.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
        return (entry as? [String: Any])?["message"] as? String
    }

    static func runExtensions() async -> [Finding] {
        let p = extensions
        let installed = browsers.filter(\.installed)
        let multi = installed.count > 1
        let all = installed.flatMap { b in installedExtensions(of: b).map { (b.label, $0) } }
        if all.isEmpty {
            return [Finding(
                probeId: p.id, scope: p.scope, severity: .green, tag: .speed,
                summary: "No user-installed browser extensions",
                explain: "Nothing to review — no extensions are installed in your browsers (built-in browser "
                    + "components aren't counted).")]
        }
        let bg = all.filter { $0.1.background }.count
        // The page's overview grouping keys off "N extensions ·" — this is the
        // overview row that nests the per-extension rows below it.
        var out = [Finding(
            probeId: p.id, scope: p.scope, severity: .green, tag: .speed,
            summary: "\(all.count) extension\(all.count == 1 ? "" : "s") · \(bg) run in background",
            explain: "Every installed browser extension, read from its on-disk manifest. Ones with a background "
                + "page / service worker keep a process alive even when unused — that's the memory cost. Turning "
                + "an extension off or removing it can't be safely automated from outside the browser, so each "
                + "row opens that extension's own page in the browser, where you can do it.")]
        for (label, e) in all {
            let activation = e.background ? "runs in background" : "loads on demand"
            out.append(Finding(
                probeId: p.id, scope: p.scope, severity: .green, tag: .speed,
                summary: "\(e.name) · \(multi ? "\(label) · \(activation)" : activation)",
                explain: "Opens \(label)'s own extensions page focused on \"\(e.name)\", where you can turn it off "
                    + "or Remove it — the browser owns that state, so this app never edits it directly.",
                fix: "browser_ext_manage:\(label):\(e.id)"))
        }
        return out
    }

    /// Open a browser's own management page for one extension. Non-destructive
    /// (it only navigates the browser), so no confirm. `spec` = "<label>:<id>";
    /// both are validated against the real installed set.
    static func manageExtension(_ spec: String) async throws -> String {
        guard let colon = spec.firstIndex(of: ":") else { throw AppError.notFound("bad extension ref: \(spec)") }
        let label = String(spec[..<colon]), id = String(spec[spec.index(after: colon)...])
        guard let b = browser(label), b.installed else { throw AppError.notFound("no such browser: \(label)") }
        guard installedExtensions(of: b).contains(where: { $0.id == id }) else {
            throw AppError.notFound("\(label) has no extension \(id)")
        }
        let opened = (try? await Proc.run("open", ["-a", b.app, "chrome://extensions/?id=\(id)"]))?.ok ?? false
        guard opened else { throw AppError.shell("couldn't open \(label)") }
        return "Opened \(label)'s extensions page — turn it off or Remove it there"
    }
}
