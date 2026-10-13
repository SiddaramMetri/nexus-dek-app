import AppKit
import NexusCore
import SwiftUI

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
                HStack(spacing: 6) {
                    Text(slot.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    if let job = slot.running.first?.launchdJob, job.isUserAgent { AutoRestartBadge(job: job) }
                }
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
                Button {
                    LaunchdPrompt.stop(p, name: slot.name, projectRoot: group.key, model: model, fallback: onStop)
                } label: { Image(systemName: "stop.circle").foregroundStyle(.red) }
                    .help(p.launchdJob?.isUserAgent == true ? "Stop \(slot.name) (and its auto-restart job)" : "Stop \(slot.name)")
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

