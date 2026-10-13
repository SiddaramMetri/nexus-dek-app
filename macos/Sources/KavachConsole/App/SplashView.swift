import AppKit
import KavachCore
import SwiftUI

/// Launch splash: brand, what the app does, and what it's loading. Fades out
/// as soon as the first data is in (ports read, projects listed) — at least
/// briefly so it doesn't flash, never longer than `maxShow`.
struct SplashView: View {
    let status: String

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
            VStack(spacing: 6) {
                Text(AppInfo.name).font(.system(size: 30, weight: .bold, design: .rounded))
                Text(AppInfo.tagline).font(.title3).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                pillar("square.stack.3d.down.right", "Projects")
                pillar("network", "Ports")
                pillar("folder.badge.minus", "Cleanup")
                pillar("wrench.and.screwdriver", "Tools")
            }
            .padding(.top, 6)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status).font(.callout).foregroundStyle(.secondary).contentTransition(.opacity)
            }
            .padding(.top, 10)
            .animation(.easeInOut(duration: 0.2), value: status)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(AppInfo.name) is starting. \(status)")
    }

    private func pillar(_ symbol: String, _ label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Decides when the splash goes away and what it says meanwhile.
@MainActor @Observable
final class SplashState {
    static let minShow: Duration = .milliseconds(600)
    static let maxShow: Duration = .milliseconds(1500)

    var visible = true
    var status = "Starting up…"

    func run() async {
        let clock = ContinuousClock()
        let start = clock.now
        while visible {
            let ports = PortsStore.shared.snapshot != nil
            let projects = !ProjectsModel.shared.projects.isEmpty || ProjectsModel.shared.loadedAt != nil
            status = !ports ? "Reading ports…" : !projects ? "Loading your projects…" : "Ready"
            let elapsed = clock.now - start
            if (ports && projects && elapsed >= Self.minShow) || elapsed >= Self.maxShow {
                withAnimation(.easeOut(duration: 0.35)) { visible = false }
                return
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
    }
}
