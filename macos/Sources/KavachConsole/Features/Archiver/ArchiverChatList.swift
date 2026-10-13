import KavachCore
import SwiftUI

/// Age filter for the chat list — "Archive…" archives exactly what's shown.
enum ChatAgeFilter: Int, CaseIterable, Identifiable {
    case all = 0, d7 = 7, d14 = 14, d30 = 30, d90 = 90
    var id: Int { rawValue }
    var label: String { self == .all ? "Any age" : "Older than \(rawValue) days" }
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

/// A pane-local search field (the shared `SearchField` also grabs ⌘F focus,
/// which only the chat list should do).
struct PaneSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// One chat in the middle pane. The checkbox selects for bulk actions; the
/// rest of the row opens the chat. Message count loads lazily (whole-file
/// scans are cached and run one at a time).
struct ChatListRow: View {
    let chat: ArchivedChat
    let location: ChatLocation
    let isChecked: Bool
    let isOpen: Bool
    let toggle: () -> Void
    let open: () -> Void

    @ViewState private var stats: ChatStats?

    var body: some View {
        let date = Date(timeIntervalSince1970: TimeInterval(chat.epoch))
        HStack(alignment: .top, spacing: 10) {
            ChatCheckbox(isOn: isChecked, label: "Select \(chat.title)", action: toggle)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(chat.title).font(.body.weight(isOpen ? .semibold : .regular)).lineLimit(2)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    Text(detail(date))
                    Spacer(minLength: 4)
                    if chat.bytes > 0 { Text(Format.bytes(chat.bytes)) }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(Format.time(date))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isOpen ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, open)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(background, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: open) // the checkbox button keeps its own taps
        .task(id: "\(chat.file)@\(chat.epoch)") {
            stats = try? await ClaudeChats.stats(location, file: chat.file)
        }
    }

    private func detail(_ date: Date) -> String {
        let ago = Format.relative(date)
        guard let stats else { return ago }
        return "\(stats.messages) message\(stats.messages == 1 ? "" : "s") · \(ago)"
    }

    private var background: Color {
        if isOpen { return Color.accentColor.opacity(0.16) }
        return isChecked ? Color.accentColor.opacity(0.07) : .clear
    }
}
