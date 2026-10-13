import Foundation
import OpenDirectory

/// Checks the logged-in user's Mac password through Open Directory — the same
/// check the login window does, without any system prompt.
public enum LoginPassword {
    public enum Outcome: Equatable, Sendable {
        case ok
        case wrong
        /// Too many wrong tries — Open Directory ignores attempts for a while.
        case backoff
        /// Open Directory couldn't answer (no node, account issue…).
        case unavailable(String)
    }

    public static func verify(_ password: String, user: String = NSUserName()) -> Outcome {
        guard !password.isEmpty else { return .wrong }
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: user, attributes: nil)
            try record.verifyPassword(password)
            return .ok
        } catch let error as NSError {
            guard error.domain == ODFrameworkErrorDomain else { return .unavailable(error.localizedDescription) }
            switch error.code {
            case 5000: return .wrong  // kODErrorCredentialsInvalid
            case 5304: return .backoff  // kODErrorCredentialsAccountTemporarilyLocked
            default: return .unavailable(error.localizedDescription)
            }
        }
    }
}
