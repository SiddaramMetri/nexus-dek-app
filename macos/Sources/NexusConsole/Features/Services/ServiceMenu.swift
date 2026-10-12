import NexusCore
import SwiftUI

/// ⋯ menu: restart, install/switch version, remove from list, uninstall.
/// Versions (`brew search`, slow when cold) are warmed on hover.
struct ServiceMenu: View {
    @Environment(AppModel.self) private var model
    let service: ReconciledService
    @ViewState private var versions: [String]?
    @ViewState private var loading = false
    @ViewState private var uninstallOpen = false

    var body: some View {
        let installed = service.status != .notInstalled
        Menu {
            if service.isRunning {
                Button { model.restartService(service) } label: { Label("Restart", systemImage: "arrow.clockwise") }
                Divider()
            }
            Section("Install / switch version") {
                if let versions {
                    if versions.isEmpty {
                        Text("No versions found.")
                    }
                    ForEach(versions, id: \.self) { v in
                        let current = installed && v == service.formula
                        Button { model.switchVersion(service, to: v) } label: {
                            if current { Label(v, systemImage: "checkmark") } else { Text(v) }
                        }
                        .disabled(current)
                    }
                    if versions.count == 1 { Text("Homebrew has no other version of this formula.") }
                } else {
                    Text("Loading versions…")
                }
            }
            Divider()
            Button { model.removeManaged(service.formula) } label: { Label("Remove from list", systemImage: "list.bullet.indent") }
            if installed {
                Button(role: .destructive) { uninstallOpen = true } label: {
                    Label("Uninstall \(baseName)", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .onHover { if $0 { loadVersions() } }
        .sheet(isPresented: $uninstallOpen) { PackageUninstallSheet(name: service.formula) }
    }

    private var baseName: String {
        bareFormula(service.formula).split(separator: "@").first.map(String.init) ?? service.formula
    }

    private func loadVersions() {
        guard versions == nil, !loading else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                versions = try await model.services.versions(service.formula)
            } catch {
                versions = service.status != .notInstalled ? [service.formula] : []
            }
        }
    }
}
