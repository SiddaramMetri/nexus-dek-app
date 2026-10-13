import AppKit
import NexusCore
import SwiftUI

/// One project on the Projects tab, in the Ports tab's card language: identity
/// + ⋯ menu, chips (branch, git state, running, last activity), its declared
/// servers as `ServerRow`s, removable disk, and an action bar.
struct ProjectOverviewCard: View {
    @Environment(AppModel.self) private var model
    let project: ProjectInfo
    /// Live ports anywhere (the card picks its own).
    let ports: [PortInfo]
    let removable: UInt64?
    let onStop: (PortInfo) -> Void
    @ViewState private var stopping = false

    private var store: ProjectsModel { .shared }
    private var isPinned: Bool { store.pinned.contains(project.root) }
    /// nil = not loaded yet; .some(nil) = not a repo or git failed.
    private var gitStatus: GitSafety.Status?? { store.git[project.root] }

    private var group: PortGroup {
        ProjectList.group(for: project, ports: ports, branch: (gitStatus ?? nil)?.branch ?? project.branch)
    }

    var body: some View {
        let group = group
        let running = group.servers.filter(\.isRunning)
        let stopped = group.servers.filter { !$0.isRunning && $0.declared != nil }
        VStack(alignment: .leading, spacing: 0) {
            header(group, running: running)
            chips(group, running: running).padding(.top, 10)
            servers(group).padding(.top, 12)
            if let removable, removable > 0 { disk(removable).padding(.top, 10) }
            StoppedJobsRow(projectRoot: project.root).padding(.top, 6)
            Spacer(minLength: 12)
            Divider()
            ProjectActionBar(group: group, running: running, stopped: stopped, stopping: stopping,
                             openTerminal: openTerminal, stopAll: { stopProject(group) })
                .padding(.top, 10)
        }
        .card()
        .onAppear { store.requestGit(project.root) }
    }

    // MARK: - Header

    private func header(_ group: PortGroup, running: [ServerSlot]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(project.name).font(.headline).lineLimit(1)
                    if isPinned {
                        Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                            .help("Pinned").accessibilityLabel("Pinned")
                    }
                }
                Text(group.subtitle ?? project.root).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(project.root)
            }
            Spacer(minLength: 4)
            Menu {
                Button { PortActions.revealInFinder(project.root) } label: { Label("Show in Finder", systemImage: "folder") }
                if PortActions.vsCodeURL != nil {
                    Button { PortActions.openInVSCode(project.root) } label: {
                        Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                Button { openTerminal() } label: { Label("Open terminal here", systemImage: "terminal") }
                Button { PortActions.copy(project.root) } label: { Label("Copy path", systemImage: "doc.on.doc") }
                Divider()
                Button { store.togglePin(project.root) } label: {
                    Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
    }

    // MARK: - Chips

    private func chips(_ group: PortGroup, running: [ServerSlot]) -> some View {
        HStack(spacing: 6) {
            if let branch = group.branch { BranchChip(branch: branch) }
            GitStateChip(status: gitStatus)
            if !group.servers.isEmpty { ServersRunningChip(running: running.count, total: group.servers.count) }
            Spacer(minLength: 4)
            if let date = project.lastActivity {
                Text(Format.relative(date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Last activity: \(Format.time(date))")
            }
        }
    }

    // MARK: - Servers

    @ViewBuilder
    private func servers(_ group: PortGroup) -> some View {
        if group.servers.isEmpty {
            Group {
                if let l = group.launcher {
                    Text("No dev servers listed · Start all runs \(l.launchLabel)").help(l.command)
                } else {
                    Text("No dev servers declared")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
            VStack(spacing: 0) {
                ForEach(group.servers) { slot in
                    ServerRow(group: group, slot: slot, onStop: onStop)
                    if slot.id != group.servers.last?.id { Divider().padding(.leading, 22) }
                }
            }
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
        }
    }

    // MARK: - Disk

    private func disk(_ bytes: UInt64) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "internaldrive").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("\(Format.bytes(bytes)) removable").monospacedDigit()
            Button("Review in Dev cleanup") {
                CleanupModel.shared.focusedGroup = project.root
                model.tab = .cleanup
            }
            .buttonStyle(.link)
            .disabled(!model.visibleTabs.contains(.cleanup))
        }
        .font(.callout)
        .help("Build folders and dependencies from the last Dev cleanup scan")
    }

    // MARK: - Actions

    private func openTerminal() {
        model.terminals.runInProject(dir: project.root, title: project.name, command: "")
    }

    private func stopProject(_ group: PortGroup) {
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

/// Open, Start all / Start rest / Stop all, Terminal, VS Code (or Finder) —
/// equal width, the same rules as the Ports tab's project card.
private struct ProjectActionBar: View {
    @Environment(AppModel.self) private var model
    let group: PortGroup
    let running: [ServerSlot]
    let stopped: [ServerSlot]
    let stopping: Bool
    let openTerminal: () -> Void
    let stopAll: () -> Void

    /// The running frontend, else the first running server.
    private var primaryPort: PortInfo? {
        (running.first { $0.role == .frontend } ?? running.first)?.running.first
    }

    /// Nothing running and the project has a whole-stack script → use it.
    private var useLauncher: Bool { running.isEmpty && group.launcher != nil }

    var body: some View {
        HStack(spacing: 6) {
            Button { if let p = primaryPort { PortActions.open(p) } } label: {
                Label("Open", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity)
            }
            .disabled(primaryPort == nil)
            .help(primaryPort.map { "Open http://localhost:\(String($0.port))" } ?? "Nothing running to open")

            startOrStop

            Button(action: openTerminal) {
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

    @ViewBuilder
    private var startOrStop: some View {
        if group.servers.isEmpty && group.launcher == nil {
            Button {} label: { Label("Start all", systemImage: "play.fill").frame(maxWidth: .infinity) }
                .disabled(true)
                .help("This project declares no dev servers")
        } else if stopped.isEmpty && !useLauncher {
            Button(role: .destructive, action: stopAll) {
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
    }

    private func startAll() {
        if useLauncher, let l = group.launcher {
            ServerRow.start(l, name: "everything", project: group.title, model: model)
        } else {
            for slot in stopped { ServerRow.start(slot, project: group.title, model: model) }
        }
    }
}

/// "Clean" / "3 uncommitted · 2 unpushed" (orange) / "No remote branch".
/// Hidden for folders that aren't git repositories.
private struct GitStateChip: View {
    let status: GitSafety.Status??

    var body: some View {
        switch status {
        case .none:
            Text("Checking git…")
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .foregroundStyle(.tertiary)
                .background(.quaternary.opacity(0.4), in: Capsule())
        case .some(nil):
            EmptyView()
        case let .some(.some(s)):
            let unsaved = s.hasUnsavedWork
            Label(short(s), systemImage: unsaved ? "exclamationmark.circle" : "checkmark.circle")
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .foregroundStyle(unsaved ? Color.orange : Color.secondary)
                .background((unsaved ? Color.orange : Color.secondary).opacity(0.12), in: Capsule())
                .help(s.summary.prefix(1).uppercased() + s.summary.dropFirst())
        }
    }

    private func short(_ s: GitSafety.Status) -> String {
        var parts: [String] = []
        if s.changed > 0 { parts.append("\(s.changed) uncommitted") }
        if s.ahead > 0 { parts.append("\(s.ahead) unpushed") }
        if parts.isEmpty { return s.noUpstream ? "No remote branch" : "Clean" }
        return parts.joined(separator: " · ")
    }
}

/// "Stopped" / "1 of 2 running" / "All 2 running" — color plus text.
private struct ServersRunningChip: View {
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
