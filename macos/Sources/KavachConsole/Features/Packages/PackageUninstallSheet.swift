import KavachCore
import SwiftUI

/// Uninstall confirm with a dependents check (`brew uses --installed`): when
/// other installed packages need this one, the action becomes "Uninstall anyway"
/// and runs with --ignore-dependencies.
struct PackageUninstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let name: String

    @ViewState private var dependents: [String]?
    @ViewState private var running = false

    private var blocked: Bool { !(dependents ?? []).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Uninstall \(name)?").font(.headline)
                Text("Runs brew uninstall.").font(.callout).foregroundStyle(.secondary)
            }

            if let deps = dependents {
                if deps.isEmpty {
                    Text("Remove \(name) from Homebrew.").font(.callout).foregroundStyle(.secondary)
                } else {
                    dependentsWarning(deps)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking dependents…").font(.callout).foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(blocked ? "Uninstall anyway" : "Uninstall", role: .destructive) { run() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(running || dependents == nil)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
        .task { await loadDependents() }
    }

    private func dependentsWarning(_ deps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("\(deps.count) installed package\(deps.count > 1 ? "s" : "") depend\(deps.count > 1 ? "" : "s") on \(name). "
                    + "Uninstalling anyway may break \(deps.count > 1 ? "them" : "it").")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(deps, id: \.self) { d in
                        Text(d).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }

    private func loadDependents() async {
        do {
            dependents = try await PackagesBackend(brew: model.brew).dependents(name)
        } catch {
            // Couldn't check — fall back to a plain uninstall (brew still refuses if needed).
            if !Task.isCancelled { model.report(error) }
            dependents = []
        }
    }

    private func run() {
        running = true
        let ignore = blocked
        Task {
            let ok = await PackagesStore.shared.uninstall(name, ignoreDependents: ignore, model: model)
            running = false
            if ok { dismiss() }
        }
    }
}
