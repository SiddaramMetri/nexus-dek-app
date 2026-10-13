import KavachCore
import SwiftUI

extension ReconciledService {
    var isRunning: Bool { status == .running || status == .starting }
    var isBusy: Bool { status == .starting || status == .stopping }

    /// Icon per formula (ignoring tap and @version).
    var symbol: String {
        let base = bareFormula(formula).split(separator: "@").first.map(String.init) ?? formula
        switch base {
        case "redis", "valkey": return "square.stack.3d.up"
        case "nginx": return "globe"
        case "postgresql", "postgres", "mysql", "mariadb", "mongodb", "mongodb-community", "memcached":
            return "cylinder.split.1x2"
        default: return "shippingbox"
        }
    }
}

struct ServiceCard: View {
    let service: ReconciledService

    var body: some View {
        let installed = service.status != .notInstalled
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                ServiceIcon(service: service, dim: installed)
                VStack(alignment: .leading, spacing: 2) {
                    Text(service.displayName).font(.headline).lineLimit(1)
                    Text(service.formula + (service.port.map { " · :\($0)" } ?? ""))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                ServiceMenu(service: service)
            }
            HStack(spacing: 6) {
                StatusChip(status: service.status)
                if installed { LinkChip(link: service.linkState) }
            }
            .padding(.top, 10)
            if installed {
                ServiceStats(service: service).padding(.top, 8)
            }
            Spacer(minLength: 10)
            Divider()
            ServiceActions(service: service, compact: false).padding(.top, 10)
        }
        .frame(minHeight: 168, alignment: .top)
        .card()
    }
}

struct ServiceRow: View {
    let service: ReconciledService

    var body: some View {
        HStack(spacing: 12) {
            ServiceIcon(service: service, dim: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.displayName).font(.headline).lineLimit(1)
                Text(service.formula + (service.port.map { " · :\($0)" } ?? ""))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(minWidth: 96, alignment: .leading)
            Spacer()
            StatusChip(status: service.status)
            if service.status != .notInstalled { LinkChip(link: service.linkState) }
            if service.isRunning { ServiceStats(service: service).frame(width: 220) }
            ServiceActions(service: service, compact: true)
            ServiceMenu(service: service)
        }
        .card(padding: 10)
    }
}

private struct ServiceIcon: View {
    let service: ReconciledService
    let dim: Bool

    var body: some View {
        Image(systemName: service.symbol)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .opacity(dim ? 0.7 : 1)
    }
}

/// Linked = registered with launchd (survives quit). Unlinked = ephemeral run.
struct LinkChip: View {
    let link: LinkState

    var body: some View {
        let linked = link == .linked
        HStack(spacing: 5) {
            Circle().fill(linked ? Color.accentColor : Color.secondary).frame(width: 6, height: 6)
            Text(linked ? "Linked" : "Unlinked").font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background((linked ? Color.accentColor : Color.secondary).opacity(0.12), in: Capsule())
        .foregroundStyle(linked ? Color.accentColor : Color.secondary)
        .help(linked ? "Kept running in the background (survives quit)." : "Runs temporarily; stops when you quit \(AppInfo.shortName).")
    }
}

/// CPU · memory · uptime. A stopped service reads 0 so cards stay uniform.
struct ServiceStats: View {
    let service: ReconciledService

    var body: some View {
        HStack(spacing: 18) {
            Stat(label: "CPU", value: Format.percent(service.cpu ?? 0))
            Stat(label: "Memory", value: Format.bytes(service.memoryBytes ?? 0))
            Stat(label: "Uptime", value: Format.duration(service.uptimeSecs ?? 0))
        }
    }
}

struct ServiceActions: View {
    @Environment(AppModel.self) private var model
    let service: ReconciledService
    let compact: Bool

    var body: some View {
        if service.status == .notInstalled {
            Button { model.install(service) } label: { Label("Install", systemImage: "arrow.down.circle") }
                .disabled(service.isBusy)
        } else {
            let linked = service.linkState == .linked
            let power = powerState
            HStack(spacing: 6) {
                if power.stop {
                    action("Stop", "stop.fill", role: .destructive, loading: power.loading, disabled: power.disabled) {
                        model.stopService(service)
                    }
                } else {
                    action("Start", "play.fill", loading: power.loading, disabled: power.disabled) {
                        model.startService(service)
                    }
                }
                action(linked ? "Unlink" : "Link", linked ? "link.badge.plus" : "link", disabled: power.loading) {
                    model.setLink(service, linked ? .unlinked : .linked)
                }
                action("CLI", "terminal") {
                    model.terminals.open(formula: service.formula, title: service.displayName, kind: .cli)
                }
                action("Logs", "doc.text") {
                    model.terminals.open(formula: service.formula, title: "\(service.displayName) · logs", kind: .logs)
                }
            }
        }
    }

    /// Start/Stop face from the REAL status plus the in-flight brew command.
    /// Disabled only while the command itself runs, so a service that's slow
    /// to become healthy (`starting`) stays abortable via Stop.
    private var powerState: (stop: Bool, loading: Bool, disabled: Bool) {
        switch model.pending[service.formula] {
        case .starting?: return (false, true, true)
        case .some: return (true, true, true)
        case nil: break
        }
        switch service.status {
        case .starting, .stopping: return (true, true, false)
        case .running: return (true, false, false)
        default: return (false, false, false)
        }
    }

    @ViewBuilder
    private func action(_ label: String, _ symbol: String, role: ButtonRole? = nil, loading: Bool = false,
                        disabled: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(role: role, action: run) {
            if loading {
                ProgressView().controlSize(.small).frame(maxWidth: compact ? nil : .infinity)
            } else if compact {
                Image(systemName: symbol)
            } else {
                Label(label, systemImage: symbol).frame(maxWidth: .infinity)
            }
        }
        .disabled(disabled)
        .help(label)
        .controlSize(compact ? .regular : .small)
    }
}
