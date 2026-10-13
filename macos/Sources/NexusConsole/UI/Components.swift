import NexusCore
import SwiftUI

// Shared, native-looking building blocks. System colors and fonts only — the
// app should read as a first-party macOS utility.

extension DisplayStatus {
    var label: String {
        switch self {
        case .running: "Running"
        case .starting: "Starting"
        case .stopping: "Stopping"
        case .stopped: "Stopped"
        case .notInstalled: "Not installed"
        case .error: "Error"
        }
    }

    var color: Color {
        switch self {
        case .running: .green
        case .starting, .stopping: .orange
        case .stopped, .notInstalled: .secondary
        case .error: .red
        }
    }
}

/// Status = colored dot + label, never color alone.
struct StatusChip: View {
    let status: DisplayStatus

    var body: some View {
        HStack(spacing: 5) {
            if status == .starting || status == .stopping {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(status.color).frame(width: 7, height: 7)
            }
            Text(status.label).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.12), in: Capsule())
        .foregroundStyle(status == .stopped || status == .notInstalled ? Color.secondary : status.color)
        .accessibilityElement(children: .combine)
    }
}

/// Page header: title + optional subtitle on the left, actions on the right.
/// Fixed height so swapping its contents never shifts the layout.
struct PageHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 12)
            actions
        }
        .frame(height: 52)
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Centered empty / not-detected state.
struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String?
    var action: (label: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            if let action { Button(action.label, action: action.run).padding(.top, 4) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Inline error with an optional retry / fix button.
struct ErrorPanel: View {
    let error: AppError
    var retry: (() -> Void)?
    var trustTap: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: error.kind == "busy" ? "hourglass" : "exclamationmark.triangle.fill")
                .foregroundStyle(error.kind == "busy" ? Color.secondary : Color.red)
            Text(error.message).font(.callout).textSelection(.enabled)
            Spacer()
            if case let .untrustedTap(tap) = error, let trustTap {
                Button("Trust \(tap)…") { trustTap(tap) }
            }
            if let retry { Button("Retry", action: retry) }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The one card surface: 1px border + subtle fill, no nested cards.
struct CardStyle: ViewModifier {
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

extension View {
    func card(padding: CGFloat = 14) -> some View { modifier(CardStyle(padding: padding)) }
}

/// Small label/value pair used in stat rows.
struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }
}

/// Bottom-trailing toast stack.
struct ToastStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(model.toasts) { t in
                HStack(spacing: 8) {
                    Image(systemName: t.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(t.isError ? Color.red : Color.green)
                    Text(t.message).font(.callout).lineLimit(3)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 420, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
                .onTapGesture { model.toasts.removeAll { $0.id == t.id } }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.toasts)
        .padding(20)
    }
}

/// Search field matching the system look.
struct SearchField: View {
    @Environment(AppModel.self) private var model
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .frame(maxWidth: 260)
        .onChange(of: model.searchFocusToken) { _, _ in focused = true }
    }
}

/// Header quick toggle between light and dark (sets an explicit theme).
struct ThemeToggle: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    var showsLabel = false

    var body: some View {
        let dark = scheme == .dark
        let title = dark ? "Light mode" : "Dark mode"
        Button { model.toggleTheme(currentlyDark: dark) } label: {
            if showsLabel {
                Label(title, systemImage: dark ? "sun.max" : "moon").font(.callout)
            } else {
                Image(systemName: dark ? "sun.max" : "moon")
            }
        }
        .help(dark ? "Switch to light theme (⇧⌘L)" : "Switch to dark theme (⇧⌘L)")
        .accessibilityLabel(dark ? "Switch to light theme" : "Switch to dark theme")
    }
}

/// Floating "Installing redis… Homebrew can take a minute." while slow work runs
/// (the Homebrew hint only for brew work).
/// Overlays the page (bottom-left; toasts own bottom-right) so nothing shifts.
struct ActivityBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let first = model.activities.first {
            let more = model.activities.count - 1
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(first.label + (more > 0 ? " +\(more) more" : "") + "…").font(.callout.weight(.medium))
                if first.brew {
                    Text("Homebrew can take a minute.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
            .padding(20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
