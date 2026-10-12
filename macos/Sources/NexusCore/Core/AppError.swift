import Foundation

/// One error type across the app. `kind` mirrors the Rust/TS contract so the UI
/// can treat `cancelled` (a dismissed confirm) and `busy` (brew mid-operation)
/// as calm, non-red states.
public enum AppError: Error, Equatable, Sendable, LocalizedError {
    case shell(String)
    case parse(String)
    case invalidName(String)
    case forbidden(String)
    case notFound(String)
    case io(String)
    /// User dismissed a native confirm — never an actual failure.
    case cancelled(String)
    /// A third-party tap Homebrew hasn't been told to trust. Carries the tap.
    case untrustedTap(String)
    /// Homebrew is mid-operation; transient and self-clearing.
    case busy(String)

    public var kind: String {
        switch self {
        case .shell: "shell"
        case .parse: "parse"
        case .invalidName: "invalidName"
        case .forbidden: "forbidden"
        case .notFound: "notFound"
        case .io: "io"
        case .cancelled: "cancelled"
        case .untrustedTap: "untrustedTap"
        case .busy: "busy"
        }
    }

    public var message: String {
        switch self {
        case let .shell(m), let .parse(m), let .invalidName(m), let .forbidden(m),
             let .notFound(m), let .io(m), let .cancelled(m), let .busy(m):
            m
        case let .untrustedTap(tap):
            "Homebrew won't load anything from the untrusted tap “\(tap)”."
        }
    }

    public var errorDescription: String? { message }

    public var isCancelled: Bool { if case .cancelled = self { true } else { false } }

    /// Wrap any thrown error as an AppError (Foundation errors become `.io`).
    public static func from(_ error: Error) -> AppError {
        (error as? AppError) ?? .io(error.localizedDescription)
    }

    public static let userCancelled = AppError.cancelled("Cancelled — nothing changed.")
}

/// Native confirm gate. NexusCore mutations that touch user data take one of
/// these, so the UI can never skip the prompt. The app supplies an NSAlert sheet.
public protocol Confirmer: Sendable {
    func confirm(title: String, message: String, action: String, destructive: Bool) async -> Bool
}

extension Confirmer {
    /// Throws `.cancelled` when the user says no.
    public func require(title: String, message: String, action: String, destructive: Bool) async throws {
        guard await confirm(title: title, message: message, action: action, destructive: destructive) else {
            throw AppError.userCancelled
        }
    }
}
