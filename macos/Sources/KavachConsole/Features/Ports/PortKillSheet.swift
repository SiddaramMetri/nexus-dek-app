import KavachCore
import SwiftUI

/// Stop confirm: Stop (SIGTERM) or Force (SIGKILL). A permission-denied kill
/// switches the sheet to "Kill with admin…", which escalates through the
/// native administrator prompt.
struct PortKillSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: PortInfo

    @ViewState private var needsAdmin = false
    @ViewState private var running = false

    private var systemOwned: Bool { target.user == "root" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stop \(target.command)?").font(.headline).lineLimit(2)
                Text("PID \(String(target.pid)) · port :\(String(target.port)) · \(target.user)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if systemOwned || needsAdmin {
                Label {
                    Text(needsAdmin
                        ? "Permission denied — this process needs administrator privileges to stop."
                        : "System-owned process. Killing it may destabilize macOS.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if needsAdmin {
                    Button("Kill with admin…", role: .destructive) { kill(force: false, sudo: true) }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } else {
                    Button("Force") { kill(force: true, sudo: false) }
                        .help("Send SIGKILL — the process can't clean up")
                    Button("Stop", role: .destructive) { kill(force: false, sudo: false) }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .help("Send SIGTERM")
                }
            }
            .disabled(running)
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
    }

    /// Names the project and dev server so it's clear what goes away.
    private var detail: String {
        var what = target.framework.map { "\(target.command) (\($0))" } ?? target.command
        if case let .project(root) = target.owner { what += " in \((root as NSString).lastPathComponent)" }
        return "Stops \(what), which is listening on port :\(String(target.port))."
    }

    private func kill(force: Bool, sudo: Bool) {
        running = true
        Task {
            defer { running = false }
            do {
                try await PortsStore.shared.kill(target, force: force, sudo: sudo)
                dismiss()
            } catch {
                let e = AppError.from(error)
                // Permission denied → offer the admin prompt inline instead of a toast.
                if e == Ports.permissionDenied, !sudo {
                    needsAdmin = true
                } else {
                    model.report(e)
                }
            }
        }
    }
}
