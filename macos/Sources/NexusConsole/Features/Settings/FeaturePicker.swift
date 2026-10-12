import NexusCore
import SwiftUI

extension ModuleID {
    var label: String {
        switch self {
        case .homebrew: "Homebrew"
        case .ports: "Ports"
        case .doctor: "Doctor"
        case .claude: "Claude Chats"
        }
    }

    var symbol: String {
        switch self {
        case .homebrew: "square.grid.2x2"
        case .ports: "network"
        case .doctor: "stethoscope"
        case .claude: "archivebox"
        }
    }

    var blurb: String {
        switch self {
        case .homebrew: "Services, packages and versions."
        case .ports: "See what's listening, kill what's stuck."
        case .doctor: "Read-only machine health checks and cleanup."
        case .claude: "Browse and archive your Claude Code history."
        }
    }

    /// What runs while it's on. nil = nothing in the background.
    var background: String? {
        switch self {
        case .homebrew: "Checks Homebrew every few seconds and keeps the menu-bar count live."
        case .ports: nil
        case .doctor: "Optional daily VSCode cleanup while the app sits in the tray."
        case .claude: "Optional daily chat archiving while the app sits in the tray."
        }
    }

    /// Only Claude Chats needs something on this Mac to be offered at all.
    var isAvailable: Bool { self != .claude || ClaudeArchiver.isInstalled }
}

/// Module cards shared by the first-run screen and Settings → Features. At
/// least one module must stay on — refusing the last uncheck says why.
struct FeaturePicker: View {
    @Binding var selection: [ModuleID]
    @ViewState private var blocked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(Array(ModuleID.allCases.enumerated()), id: \.element) { i, m in
                    card(m, index: i + 1)
                }
            }
            Text(blocked ? "Keep at least one feature on." : " ")
                .font(.caption).foregroundStyle(.red)
                .accessibilityHidden(!blocked)
        }
    }

    private func card(_ m: ModuleID, index: Int) -> some View {
        let checked = selection.contains(m) && m.isAvailable
        return Button { toggle(m) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: m.symbol)
                        .frame(width: 32, height: 32)
                        .foregroundStyle(checked ? Color.white : Color.secondary)
                        .background(checked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                                    in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.label).font(.headline)
                        Text(m.blurb).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                }
                Text(m.isAvailable ? (m.background ?? "Nothing runs in the background.") : "Claude Code not found on this Mac.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
            .background(checked ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(checked ? Color.accentColor : Color(nsColor: .separatorColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!m.isAvailable)
        .opacity(m.isAvailable ? 1 : 0.6)
        .keyboardShortcut(KeyEquivalent(Character(String(index))), modifiers: [])
        .accessibilityLabel(m.label)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    private func toggle(_ m: ModuleID) {
        let next = selection.contains(m) ? selection.filter { $0 != m } : selection + [m]
        guard !next.isEmpty else { blocked = true; return }
        blocked = false
        selection = ModuleID.allCases.filter(next.contains)
    }
}
