import AppKit
import KavachCore
import SwiftUI

/// One installed tool: icon · name + how it was installed · installed → latest
/// · status · Update (or Re-check after an update ran) · ⋯ menu.
struct ToolRow: View {
    let tool: DevTool
    let status: ToolStatus
    let isChecking: Bool
    let updateLaunched: Bool
    let onUpdate: () -> Void
    let onRecheck: () -> Void

    private var updateCommand: String? { (try? ToolUpdate.command(for: tool)) ?? nil }

    var body: some View {
        HStack(spacing: 12) {
            ToolIcon(tool: tool)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name).font(.body.weight(.medium))
                Text(tool.method.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                ForEach(tool.details, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
                }
            }
            .help(tool.path)
            Spacer(minLength: 12)
            versions.frame(width: 170, alignment: .trailing)
            ToolStatusChip(status: status, isChecking: isChecking).frame(width: 150, alignment: .leading)
            action.frame(width: 84, alignment: .trailing)
            menu
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    private var versions: some View {
        HStack(spacing: 4) {
            Text(tool.version ?? "—").foregroundStyle(tool.version == nil ? .secondary : .primary)
            if case let .updateAvailable(latest?) = status {
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                Text(ToolVersion.display(latest)).foregroundStyle(Color.accentColor)
            }
        }
        .font(.callout.monospacedDigit())
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private var action: some View {
        if updateLaunched {
            Button("Re-check", action: onRecheck)
                .disabled(isChecking)
                .help("Read the installed version again and check for updates")
        } else if status.hasUpdate, updateCommand != nil {
            Button("Update", action: onUpdate)
                .buttonStyle(.borderedProminent)
                .help(updateCommand.map { "Runs \($0) in the terminal" } ?? "")
        }
    }

    private var menu: some View {
        Menu {
            if let url = tool.releaseNotes {
                Button { NSWorkspace.shared.open(url) } label: { Label("Release notes", systemImage: "doc.text") }
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tool.resolvedPath)])
            } label: { Label("Show in Finder", systemImage: "folder") }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tool.path, forType: .string)
            } label: { Label("Copy path", systemImage: "doc.on.doc") }
            Divider()
            if let cmd = updateCommand, !status.hasUpdate {
                Button(action: onUpdate) { Label("Run \(cmd)…", systemImage: "arrow.up.circle") }
            }
            Button(action: onRecheck) { Label("Re-check", systemImage: "arrow.clockwise") }
                .disabled(isChecking)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions for \(tool.name)")
    }
}

/// The app's own icon for Mac apps (read from the bundle, never launched),
/// an SF Symbol tile for CLIs.
struct ToolIcon: View {
    let tool: DevTool

    var body: some View {
        Group {
            if tool.kind == .app {
                Image(nsImage: NSWorkspace.shared.icon(forFile: tool.path)).resizable().interpolation(.high)
            } else {
                Image(systemName: tool.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

/// Status = icon + label, never color alone. Informational states stay grey.
struct ToolStatusChip: View {
    let status: ToolStatus
    let isChecking: Bool

    var body: some View {
        HStack(spacing: 5) {
            if isChecking {
                ProgressView().controlSize(.mini)
                Text("Checking…")
            } else {
                Image(systemName: symbol).font(.caption2.weight(.semibold))
                Text(status.label).lineLimit(1)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(isChecking ? 0.08 : 0.12), in: Capsule())
        .foregroundStyle(isChecking ? Color.secondary : color)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch status {
        case .upToDate: "checkmark"
        case .updateAvailable: "arrow.up"
        case .managed: "arrow.triangle.2.circlepath"
        case .couldntCheck: "questionmark"
        case .unchecked: "minus"
        }
    }

    private var color: Color {
        switch status {
        case .upToDate: .green
        case .updateAvailable: .accentColor
        case .managed, .couldntCheck, .unchecked: .secondary
        }
    }
}

/// First-load placeholder in the row shape — nothing jumps when data lands.
struct ToolsSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { i in
                if i > 0 { Divider() }
                HStack(spacing: 12) {
                    bar(28).frame(width: 28)
                    VStack(alignment: .leading, spacing: 6) {
                        bar(12).frame(width: 120)
                        bar(9).frame(width: 180)
                    }
                    Spacer()
                    bar(12).frame(width: 70)
                    bar(18).frame(width: 96)
                        .padding(.trailing, 110)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityHidden(true)
    }

    private func bar(_ height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(.quaternary).frame(height: height)
    }
}
