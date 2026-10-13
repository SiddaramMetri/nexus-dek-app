import AppKit
import KavachCore
import SwiftUI

/// Ports as a clean grouped list (System Settings style): one row per port —
/// big port number, what it is, who owns it, live stats, quick actions.
/// Project overviews live in the Projects tab; this screen is about ports.
struct PortsListView: View {
    @Environment(AppModel.self) private var model
    let sections: PortSections
    let searching: Bool
    let onStop: (PortInfo) -> Void

    private var store: PortsStore { .shared }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            if !sections.projects.isEmpty || !searching {
                section(.projects, count: projectLines.count, symbol: "folder.fill", tint: .accentColor) {
                    if projectLines.isEmpty {
                        Text("No dev servers are running in your projects.")
                            .font(.callout).foregroundStyle(.secondary).padding(14)
                    }
                    ForEach(projectLines, id: \.port.id) { line in
                        PortLine(port: line.port, title: line.name, role: line.role,
                                 owner: .project(line.group.title, line.group.key), onStop: onStop)
                        if line.port.id != projectLines.last?.port.id { Divider().padding(.leading, 96) }
                    }
                }
            }
            if !sections.other.isEmpty {
                section(.other, count: sections.other.reduce(0) { $0 + $1.ports.count }, symbol: "terminal", tint: .secondary) {
                    lines(sections.other) { g, p in
                        PortLine(port: p, title: p.framework ?? p.command, role: nil,
                                 owner: .other(g.brewService), onStop: onStop)
                    }
                }
            }
            if !sections.apps.isEmpty {
                section(.apps, count: sections.apps.reduce(0) { $0 + $1.ports.count }, symbol: "app.badge", tint: .secondary) {
                    lines(sections.apps) { g, p in
                        PortLine(port: p, title: g.title, role: nil, owner: .app(g.key), onStop: onStop)
                    }
                }
            }
            if !sections.system.isEmpty {
                section(.system, count: sections.system.reduce(0) { $0 + $1.ports.count }, symbol: "lock.fill",
                        tint: .secondary, trailing: "Protected") {
                    lines(sections.system) { g, p in
                        PortLine(port: p, title: g.title, role: nil, owner: .system(g.subtitle), onStop: onStop)
                    }
                }
            }
        }
    }

    // MARK: - Data

    struct ProjectLine {
        let group: PortGroup
        let port: PortInfo
        let name: String
        let role: ServerRole
    }

    /// Running ports of every project, frontend first.
    private var projectLines: [ProjectLine] {
        sections.projects.flatMap { g in
            g.servers.flatMap { slot in slot.running.map { ProjectLine(group: g, port: $0, name: slot.name, role: slot.role) } }
        }
    }

    // MARK: - Layout

    private func lines<Row: View>(_ groups: [PortGroup], @ViewBuilder row: @escaping (PortGroup, PortInfo) -> Row) -> some View {
        let all = groups.flatMap { g in g.ports.map { (g, $0) } }
        return ForEach(Array(all.enumerated()), id: \.element.1.id) { i, pair in
            row(pair.0, pair.1)
            if i < all.count - 1 { Divider().padding(.leading, 96) }
        }
    }

    private func isOpen(_ s: PortsStore.Section) -> Bool { searching || store.expanded.contains(s) }

    private func section<Content: View>(_ s: PortsStore.Section, count: Int, symbol: String, tint: Color,
                                        trailing: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { store.toggle(s) } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen(s) ? 90 : 0)).frame(width: 12)
                    Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
                    Text(s.title).font(.headline)
                    Text(String(count)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            if isOpen(s) {
                VStack(spacing: 0) { content() }.card(padding: 0)
            }
        }
    }
}

/// Who a port belongs to — drives the secondary line and which actions exist.
enum PortOwnerLabel {
    case project(String, String)   // name, root
    case app(String)               // bundle path
    case system(String?)           // note
    case other(String?)            // brew service
}

/// One port row.
struct PortLine: View {
    @Environment(AppModel.self) private var model
    let port: PortInfo
    let title: String
    let role: ServerRole?
    let owner: PortOwnerLabel
    let onStop: (PortInfo) -> Void

    var body: some View {
        HStack(spacing: 12) {
            portPill
            leading
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    if let role { RoleBadge(role: role) }
                    if let job = port.launchdJob, job.isUserAgent { AutoRestartBadge(job: job) }
                }
                Text(secondary).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .help(port.commandLine ?? port.command)
            Spacer(minLength: 8)
            Text(stats).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                .frame(minWidth: 150, alignment: .trailing)
            actions.frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu { PortContextMenu(port: port, onStop: onStop) }
    }

    /// The port number is the thing people scan for — make it the anchor.
    private var portPill: some View {
        Button { PortActions.open(port) } label: {
            Text(":\(String(port.port))")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(minWidth: 62)
                .padding(.vertical, 4)
                .foregroundStyle(isProtected ? Color.secondary : Color.accentColor)
                .background((isProtected ? Color.secondary : Color.accentColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help("Open http://localhost:\(String(port.port))")
    }

    @ViewBuilder
    private var leading: some View {
        switch owner {
        case let .app(bundle):
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundle)).resizable().frame(width: 22, height: 22)
        case .system:
            Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 22)
        default:
            Circle().fill(Color.green).frame(width: 8, height: 8).frame(width: 22).help("Running")
        }
    }

    private var isProtected: Bool { if case .system = owner { true } else { false } }

    private var secondary: String {
        var parts: [String] = []
        switch owner {
        case let .project(name, root): parts.append("\(name) · \(PortSections.abbreviate(root))")
        case .app: parts.append(port.command)
        case let .system(note): parts.append(note ?? port.command)
        case let .other(service): parts.append(service.map { "Homebrew service · \($0)" } ?? port.command)
        }
        if let label = PortFramework.wellKnownLabel(port: port.port), !isProtected { parts.append(label) }
        parts.append("PID \(String(port.pid))")
        return parts.joined(separator: " · ")
    }

    private var stats: String {
        guard !isProtected else { return "" }
        var parts: [String] = []
        if let up = port.uptimeSecs { parts.append("up \(Format.duration(up))") }
        if let mem = port.memoryBytes { parts.append(Format.bytes(mem)) }
        if let cpu = port.cpu { parts.append(Format.percent(cpu)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 2) {
            switch owner {
            case .system:
                EmptyView()
            case .app:
                Button { PortActions.copyURL(port) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy http://localhost:\(String(port.port))")
            default:
                Button { PortActions.copyURL(port) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy http://localhost:\(String(port.port))")
                Button {
                    var root: String?
                    if case let .project(_, r) = owner { root = r }
                    LaunchdPrompt.stop(port, name: title, projectRoot: root, model: model, fallback: onStop)
                } label: { Image(systemName: "stop.circle").foregroundStyle(.red) }
                    .help("Stop \(title)")
                    .disabled(port.isSystem)
            }
        }
        .buttonStyle(.borderless)
    }
}
