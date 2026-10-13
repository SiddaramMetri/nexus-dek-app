import AppKit
import NexusCore
import SwiftUI

/// One project as a card, in the same visual language as the Services cards:
/// identity + ⋯ menu, status chips, a row per server (Frontend / Backend / …,
/// running or not), and an action bar.
struct ProjectCard: View {
    @Environment(AppModel.self) private var model
    let group: PortGroup
    let onStop: (PortInfo) -> Void
    @ViewState private var stopping = false

    private var running: [ServerSlot] { group.servers.filter(\.isRunning) }
    private var stopped: [ServerSlot] { group.servers.filter { !$0.isRunning && $0.declared != nil } }
    /// What "Open" opens: the running frontend, else the first running server.
    private var primaryPort: PortInfo? {
        (running.first { $0.role == .frontend } ?? running.first)?.running.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(spacing: 6) {
                RunningChip(running: running.count, total: group.servers.count)
                if let branch = group.branch { BranchChip(branch: branch) }
                if let l = group.launcher {
                    Text("Start all: \(l.launchLabel)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(l.command)
                }
            }
            .padding(.top, 10)

            VStack(spacing: 0) {
                ForEach(group.servers) { slot in
                    ServerRow(group: group, slot: slot, onStop: onStop)
                    if slot.id != group.servers.last?.id { Divider().padding(.leading, 22) }
                }
            }
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
            .padding(.top, 12)

            Spacer(minLength: 12)
            Divider()
            actionBar.padding(.top, 10)
        }
        .card()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title).font(.headline).lineLimit(1)
                if let path = group.subtitle {
                    Text(path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(group.key)
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button { PortActions.revealInFinder(group.key) } label: { Label("Show in Finder", systemImage: "folder") }
                if PortActions.vsCodeURL != nil {
                    Button { PortActions.openInVSCode(group.key) } label: { Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                }
                Button { openTerminal() } label: { Label("Open terminal here", systemImage: "terminal") }
                Button { PortActions.copy(group.key) } label: { Label("Copy path", systemImage: "doc.on.doc") }
                Divider()
                Button(role: .destructive) { stopProject() } label: { Label("Stop all servers…", systemImage: "stop.circle") }
                    .disabled(running.isEmpty || stopping)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
    }

    /// Equal-width buttons, like the Services card footer.
    private var actionBar: some View {
        HStack(spacing: 6) {
            Button { if let p = primaryPort { PortActions.open(p) } } label: {
                Label("Open", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity)
            }
            .disabled(primaryPort == nil)
            .help(primaryPort.map { "Open http://localhost:\(String($0.port))" } ?? "Nothing running to open")

            if stopped.isEmpty && !(running.isEmpty && group.launcher != nil) {
                Button(role: .destructive) { stopProject() } label: {
                    Label("Stop all", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .disabled(running.isEmpty || stopping)
            } else {
                Button { startAll() } label: {
                    Label(useLauncher || stopped.count == group.servers.count ? "Start all" : "Start rest", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .help(useLauncher ? "Runs \(group.launcher?.launchLabel ?? "") — starts the whole project in the terminal"
                      : "Start \(stopped.map(\.name).joined(separator: ", ")) in the terminal")
            }

            Button { openTerminal() } label: {
                Label("Terminal", systemImage: "terminal").frame(maxWidth: .infinity)
            }
            if PortActions.vsCodeURL != nil {
                Button { PortActions.openInVSCode(group.key) } label: {
                    Label("VS Code", systemImage: "chevron.left.forwardslash.chevron.right").frame(maxWidth: .infinity)
                }
            } else {
                Button { PortActions.revealInFinder(group.key) } label: {
                    Label("Finder", systemImage: "folder").frame(maxWidth: .infinity)
                }
            }
        }
        .controlSize(.small)
    }

    private func openTerminal() {
        model.terminals.runInProject(dir: group.key, title: group.title, command: "")
    }

    /// Nothing running and the project has a whole-stack script → use it.
    private var useLauncher: Bool { running.isEmpty && group.launcher != nil }

    private func startAll() {
        if useLauncher, let l = group.launcher {
            ServerRow.start(l, name: "everything", project: group.title, model: model)
        } else {
            for slot in stopped { ServerRow.start(slot, project: group.title, model: model) }
        }
    }

    private func stopProject() {
        stopping = true
        Task {
            defer { stopping = false }
            do {
                try await PortsStore.shared.stopProject(group, confirmer: model.confirmer)
                model.toast("Stopped \(group.title)")
            } catch {
                model.report(error)
            }
        }
    }
}

/// One server inside a project card.
struct ServerRow: View {
    @Environment(AppModel.self) private var model
    let group: PortGroup
    let slot: ServerSlot
    let onStop: (PortInfo) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(slot.isRunning ? Color.green : Color.clear)
                .overlay(Circle().strokeBorder(slot.isRunning ? Color.green : Color.secondary, lineWidth: 1.2))
                .frame(width: 8, height: 8)
                .help(slot.isRunning ? "Running" : "Not running")
            RoleBadge(role: slot.role).frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(slot.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
            }
            .help(slot.running.first?.commandLine ?? slot.declared?.command ?? "")
            Spacer(minLength: 8)
            portLinks
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .opacity(slot.isRunning ? 1 : 0.85)
        .contextMenu {
            if let p = slot.running.first { PortContextMenu(port: p, onStop: onStop) }
        }
    }

    private var caption: String {
        if let p = slot.running.first {
            var parts: [String] = []
            if let up = p.uptimeSecs { parts.append("up \(Format.duration(up))") }
            if let mem = p.memoryBytes { parts.append(Format.bytes(mem)) }
            if let cpu = p.cpu { parts.append(Format.percent(cpu) + " CPU") }
            parts.append("PID \(String(p.pid))")
            return parts.joined(separator: " · ")
        }
        return "Not running" + (slot.declared.map { " · \($0.launchLabel)" } ?? "")
    }

    @ViewBuilder
    private var portLinks: some View {
        if slot.isRunning {
            HStack(spacing: 4) {
                ForEach(slot.running) { p in
                    Button(":\(String(p.port))") { PortActions.open(p) }
                        .buttonStyle(.link)
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .help("Open http://localhost:\(String(p.port))")
                }
            }
        } else if let port = slot.port {
            Text(":\(String(port))").font(.callout.monospacedDigit()).foregroundStyle(.tertiary)
                .help("Expected port")
        }
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 2) {
            if let p = slot.running.first {
                Button { PortActions.copyURL(p) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy http://localhost:\(String(p.port))")
                Button { onStop(p) } label: { Image(systemName: "stop.circle").foregroundStyle(.red) }
                    .help("Stop \(slot.name)")
                    .disabled(p.isSystem)
            } else if slot.declared != nil {
                Button { Self.start(slot, project: group.title, model: model) } label: {
                    Label("Start", systemImage: "play.fill").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Runs \(slot.declared?.launchLabel ?? "") in a terminal tab")
            }
        }
        .buttonStyle(.borderless)
        .frame(minWidth: 58, alignment: .trailing)
    }

    /// Opens a terminal tab in the server's folder and types its start command.
    static func start(_ slot: ServerSlot, project: String, model: AppModel) {
        guard let d = slot.declared else { return }
        start(d, name: slot.name, project: project, model: model)
    }

    static func start(_ d: DeclaredServer, name: String, project: String, model: AppModel) {
        do {
            let command = try ScriptLaunch.command(for: d)
            model.terminals.runInProject(dir: d.dir, title: "\(project) · \(name)", command: command)
            model.toast("Starting \(name) in \(project) — watch the terminal below")
        } catch {
            model.report(error)
        }
    }
}

/// Frontend / Backend / Database / Tool, color + text (never color alone).
struct RoleBadge: View {
    let role: ServerRole

    var body: some View {
        Text(role.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.13), in: Capsule())
    }

    private var color: Color {
        switch role {
        case .frontend: .blue
        case .backend: .purple
        case .database: .orange
        case .tool: .secondary
        }
    }
}

/// "Running" / "1 of 2 running" / "Stopped".
private struct RunningChip: View {
    let running: Int
    let total: Int

    var body: some View {
        let all = running == total && total > 0
        let color: Color = running == 0 ? .secondary : all ? .green : .orange
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(running == 0 ? "Stopped" : all ? (total == 1 ? "Running" : "All \(total) running") : "\(running) of \(total) running")
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color == .secondary ? Color.secondary : color)
        .background(color.opacity(0.12), in: Capsule())
    }
}
