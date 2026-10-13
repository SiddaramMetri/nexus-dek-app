import AppKit
import KavachCore
import Observation
import SwiftTerm
import SwiftUI

/// One PTY-backed terminal tab. The SwiftTerm view lives as long as the tab,
/// so hiding the drawer never kills a running shell.
@MainActor
final class TerminalSession: Identifiable {
    let id = UUID()
    let formula: String
    let title: String
    let kind: TerminalKind
    let view: LocalProcessTerminalView
    private let delegate: ProcessDelegate

    init(formula: String, title: String, kind: TerminalKind, program: String, args: [String],
         cwd: String? = nil, input: String? = nil, onExit: @escaping () -> Void) {
        self.formula = formula
        self.title = title
        self.kind = kind
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 260))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = .textBackgroundColor
        view.nativeForegroundColor = .textColor
        delegate = ProcessDelegate(onExit: onExit)
        view.processDelegate = delegate
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("LANG=\(ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8")")
        if let path = ProcessInfo.processInfo.environment["PATH"] { env.append("PATH=\(path)") }
        view.startProcess(executable: program, args: args, environment: env,
                          currentDirectory: cwd ?? FileManager.default.homeDirectoryForCurrentUser.path)
        // Typed into the user's own shell, exactly as if they'd typed it —
        // visible, editable history, and Ctrl+C stops it.
        if let input { view.send(data: ArraySlice(Array((input + "\r").utf8))) }
    }

    /// PTY children lead their own process group: signal the whole group so
    /// anything launched inside the shell dies too.
    func kill() {
        let pid = view.process.shellPid
        if pid > 0 { Darwin.kill(-pid, SIGHUP) }
        view.terminate()
    }
}

private final class ProcessDelegate: LocalProcessTerminalViewDelegate {
    let onExit: () -> Void
    init(onExit: @escaping () -> Void) { self.onExit = onExit }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { self.onExit() }
    }
}

@MainActor @Observable
final class TerminalManager {
    static let maxSessions = 8
    let brewPrefix: String
    var sessions: [TerminalSession] = []
    var activeID: UUID?
    var drawerOpen = false
    var drawerHeight: CGFloat = 300
    var exited: Set<UUID> = []

    init(brewPrefix: String) { self.brewPrefix = brewPrefix }

    /// Focus an existing tab for (formula, kind), or open a new one.
    func open(formula: String, title: String, kind: TerminalKind) {
        if let existing = sessions.first(where: { $0.formula == formula && $0.kind == kind }), !exited.contains(existing.id) {
            activeID = existing.id
            drawerOpen = true
            return
        }
        sessions.removeAll { s in s.formula == formula && s.kind == kind && exited.contains(s.id) }
        guard sessions.count < Self.maxSessions,
              let cmd = try? TerminalCommand.resolve(formula: formula, kind: kind, brewPrefix: brewPrefix) else { return }
        var created: TerminalSession?
        let session = TerminalSession(formula: formula, title: title, kind: kind, program: cmd.program, args: cmd.args) { [weak self] in
            if let id = created?.id { self?.exited.insert(id) }
        }
        created = session
        sessions.append(session)
        activeID = session.id
        drawerOpen = true
    }

    /// Opens a login shell in `dir` (inside the home folder) and runs a
    /// validated dev-script command there. Re-focuses an existing tab for it.
    func runInProject(dir: String, title: String, command: String) {
        let key = "script:\(dir):\(command)"
        if let existing = sessions.first(where: { $0.formula == key }), !exited.contains(existing.id) {
            activeID = existing.id
            drawerOpen = true
            return
        }
        let home = Paths.home.path
        let dir = dir.hasSuffix("/") && dir.count > 1 ? String(dir.dropLast()) : dir
        guard dir == home || dir.hasPrefix(home + "/"), FileManager.default.fileExists(atPath: dir),
              sessions.count < Self.maxSessions else { return }
        sessions.removeAll { $0.formula == key && exited.contains($0.id) }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var created: TerminalSession?
        let session = TerminalSession(formula: key, title: title, kind: .script, program: shell, args: ["-l"],
                                      cwd: dir, input: command.isEmpty ? nil : command) { [weak self] in
            if let id = created?.id { self?.exited.insert(id) }
        }
        created = session
        sessions.append(session)
        activeID = session.id
        drawerOpen = true
    }

    func close(_ id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].kill()
        sessions.remove(at: i)
        exited.remove(id)
        if activeID == id { activeID = sessions.last?.id }
        if sessions.isEmpty { drawerOpen = false }
    }

    func toggleDrawer() {
        if sessions.isEmpty {
            drawerOpen = false
        } else {
            drawerOpen.toggle()
        }
    }

    func killAll() {
        sessions.forEach { $0.kill() }
        sessions.removeAll()
    }

    var active: TerminalSession? { sessions.first { $0.id == activeID } }
}

struct TerminalDrawer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let terms = model.terminals
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(terms.sessions) { s in
                            TerminalTab(session: s, active: s.id == terms.activeID, exited: terms.exited.contains(s.id))
                        }
                    }
                }
                Spacer()
                Button { terms.drawerOpen = false } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .help("Hide terminal (⌃`)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            if let active = terms.active {
                TerminalHost(view: active.view).padding(6)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct TerminalTab: View {
    @Environment(AppModel.self) private var model
    let session: TerminalSession
    let active: Bool
    let exited: Bool

    var body: some View {
        HStack(spacing: 4) {
            Button { model.terminals.activeID = session.id } label: {
                Text(session.title + (exited ? " (exited)" : "")).font(.caption).lineLimit(1)
            }
            .buttonStyle(.plain)
            Button { model.terminals.close(session.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(.plain)
                .help("Close \(session.title)")
        }
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .foregroundStyle(active ? .primary : .secondary)
        .background(active ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Hosts the active session's AppKit view. The container keeps sessions alive
/// across tab switches; only the visible subview changes.
private struct TerminalHost: NSViewRepresentable {
    let view: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        guard view.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}
