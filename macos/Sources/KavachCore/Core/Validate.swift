import Foundation

/// Name validation for anything that becomes a brew argument. Defense in depth:
/// args are always an array, never a shell string.
public enum Validate {
    /// Lowercase alnum + `@ . _ + -`, never leading `.` or `-` (no traversal, no flags).
    static func segmentOK(_ s: Substring) -> Bool {
        guard let first = s.first, first != ".", first != "-" else { return false }
        return s.utf8.allSatisfy { b in
            (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39)
                || b == 0x40 || b == 0x2E || b == 0x5F || b == 0x2B || b == 0x2D
        }
    }

    /// `name` (core) or `user/repo/name` (third-party tap).
    public static func formula(_ name: String) throws {
        let segs = name.split(separator: "/", omittingEmptySubsequences: false)
        guard name.utf8.count <= 128, segs.count == 1 || segs.count == 3, segs.allSatisfy(segmentOK) else {
            throw AppError.invalidName("invalid formula name: \(name)")
        }
    }

    /// Exactly `user/repo`.
    public static func tap(_ tap: String) throws {
        let segs = tap.split(separator: "/", omittingEmptySubsequences: false)
        guard tap.utf8.count <= 128, segs.count == 2, segs.allSatisfy(segmentOK) else {
            throw AppError.invalidName("invalid tap name: \(tap)")
        }
    }

    public static func isFormula(_ name: String) -> Bool { (try? formula(name)) != nil }
}

/// `mongodb/brew/mongodb-community@7.0` → `mongodb-community@7.0`. brew's own
/// output (`services list`, `opt/<name>`) is always bare.
public func bareFormula(_ name: String) -> String {
    name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name
}
