import AppKit
import KavachCore
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI

/// The shield shown on every display while locked. The primary display carries
/// the unlock controls; the others show the clock only.
struct LockScreenView: View {
    let guardModel: GuardModel
    let primary: Bool

    private var locker: ScreenLocker { guardModel.locker }

    var body: some View {
        ZStack {
            LockBackdrop()
            VStack(spacing: 0) {
                clock.padding(.top, 90)
                Spacer()
                if primary { unlockArea }
                Spacer()
                footer.padding(.bottom, 36)
            }
            .padding(.horizontal, 40)
        }
        .contentShape(Rectangle())
        .onTapGesture { locker.beginUnlock() }
        .environment(\.colorScheme, .dark)
    }

    private var clock: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(spacing: 6) {
                Text(ctx.date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: 92, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var unlockArea: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)
                .shadow(color: LockPalette.gold.opacity(0.35), radius: 24)
            Text(NSFullUserName().isEmpty ? NSUserName() : NSFullUserName())
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            control.frame(height: 92, alignment: .top)
        }
        .animation(.snappy(duration: 0.25), value: locker.phase)
    }

    @ViewBuilder
    private var control: some View {
        switch locker.phase {
        case .idle:
            VStack(spacing: 10) {
                Button { locker.beginUnlock() } label: {
                    Label("Unlock", systemImage: ScreenLocker.touchIDAvailable ? "touchid" : "lock.open")
                        .font(.headline)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 9)
                        .foregroundStyle(LockPalette.navy)
                        .background(LockPalette.gold, in: Capsule())
                }
                .buttonStyle(.plain)
                hint(locker.message ?? (ScreenLocker.touchIDAvailable ? "Touch ID, or press any key" : "Press any key to enter your password"),
                     warn: locker.message != nil)
            }
        case .touchID:
            VStack(spacing: 10) {
                if let ctx = locker.authContext {
                    TouchIDPrompt(context: ctx) { locker.evaluateTouchID(ctx) }
                        .frame(width: 56, height: 56)
                        .id(ObjectIdentifier(ctx))
                }
                hint("Touch ID to unlock", warn: false)
                Button("Use password instead") { locker.usePassword() }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(LockPalette.gold)
            }
        case .password, .checking:
            PasswordEntry(locker: locker)
        }
    }

    private func hint(_ text: String, warn: Bool) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(warn ? LockPalette.gold : .white.opacity(0.7))
            .multilineTextAlignment(.center)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let status = guardModel.awakeStatus {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Label(guardModel.awakeStatus ?? status, systemImage: "cup.and.heat.waves.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.1), in: Capsule())
                }
            }
            Label("Locked by \(AppInfo.name)", systemImage: "shield.lefthalf.filled")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// Mac password field: Return submits, Esc goes back. Shakes on a wrong password.
private struct PasswordEntry: View {
    @Bindable var locker: ScreenLocker
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                SecureField("Mac password", text: $locker.password)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .focused($focused)
                    .onSubmit { locker.submitPassword() }
                    .disabled(locker.phase == .checking)
                if locker.phase == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Button { locker.submitPassword() } label: {
                        Image(systemName: "arrow.right.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(locker.password.isEmpty ? .white.opacity(0.3) : LockPalette.gold)
                    .disabled(locker.password.isEmpty)
                    .accessibilityLabel("Unlock")
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(width: 280, height: 40)
            .background(.white.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
            .modifier(Shake(amount: CGFloat(locker.wrongCount)))
            .animation(.default, value: locker.wrongCount)
            Text(locker.message ?? "Press Esc to cancel")
                .font(.callout)
                .foregroundStyle(locker.message == nil ? .white.opacity(0.6) : LockPalette.gold)
        }
        .onExitCommand { locker.cancelPassword() }
        .onAppear { focused = true }
        .onChange(of: locker.phase) { _, p in if p == .password { focused = true } }
    }
}

private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(amount * .pi * 4), y: 0))
    }
}

/// Apple's embedded Touch ID glyph — the prompt renders inside our window.
private struct TouchIDPrompt: NSViewRepresentable {
    let context: LAContext
    let onReady: () -> Void

    func makeNSView(context: Context) -> LAAuthenticationView {
        let view = LAAuthenticationView(context: self.context, controlSize: .large)
        DispatchQueue.main.async(execute: onReady)
        return view
    }

    func updateNSView(_ nsView: LAAuthenticationView, context: Context) {}
}

enum LockPalette {
    static let navy = Color(red: 0.043, green: 0.078, blue: 0.188)
    static let indigo = Color(red: 0.118, green: 0.165, blue: 0.431)
    static let gold = Color(red: 0.961, green: 0.725, blue: 0.290)
}

/// Navy → indigo with a soft gold glow, matching the app icon.
struct LockBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [LockPalette.navy, LockPalette.indigo], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [LockPalette.gold.opacity(0.14), .clear], center: .center, startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}
