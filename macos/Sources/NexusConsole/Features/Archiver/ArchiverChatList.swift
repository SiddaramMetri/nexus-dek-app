import NexusCore
import SwiftUI

/// A per-row action, surfaced in the row's "…" menu.
struct ChatAction {
    let label: String
    let symbol: String
    /// Permanent deletes render as destructive.
    var destructive = false
    var disabled = false
    var help = ""
    let act: (String) -> Void
}

/// Round macOS-style selection checkbox (Mail/Photos), with a real button and
/// selected trait underneath for VoiceOver.
struct ChatCheckbox: View {
    let isOn: Bool
    let label: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Checkbox-selectable chat list with light pagination — shared by the Live and
/// Archived sections so both read identically. Scrolls inside its own region.
struct ArchiverChatList: View {
    /// Rows render in pages of this size; "Show more" appends the next page.
    static let page = 50

    let chats: [ArchivedChat]
    @Binding var selected: Set<String>
    let actions: [ChatAction]
    @ViewState private var visible = ArchiverChatList.page

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(chats.prefix(visible))) { chat in
                    row(chat)
                    Divider().padding(.leading, 40)
                }
                if chats.count > visible {
                    let rest = chats.count - visible
                    Button("Show \(min(Self.page, rest)) more (\(rest) remaining)") { visible += Self.page }
                        .buttonStyle(.borderless)
                        .padding(12)
                }
            }
        }
    }

    private func row(_ chat: ArchivedChat) -> some View {
        let isOn = selected.contains(chat.file)
        let date = Date(timeIntervalSince1970: TimeInterval(chat.epoch))
        return HStack(spacing: 12) {
            ChatCheckbox(isOn: isOn, label: "Select \(chat.title)") { toggle(chat.file) }
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title).lineLimit(1).truncationMode(.tail)
                Text(Format.relative(date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help(Format.time(date))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { toggle(chat.file) }
            Menu {
                ForEach(actions, id: \.label) { a in
                    Button(role: a.destructive ? .destructive : nil) { a.act(chat.file) } label: {
                        Label(a.label, systemImage: a.symbol)
                    }
                    .disabled(a.disabled)
                    .help(a.help)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Chat actions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isOn ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private func toggle(_ file: String) {
        if selected.contains(file) { selected.remove(file) } else { selected.insert(file) }
    }
}
