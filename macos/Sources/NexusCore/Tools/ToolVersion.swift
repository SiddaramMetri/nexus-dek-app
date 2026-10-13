import Foundation

/// Version strings as tools print them, and a lenient semver comparison.
public enum ToolVersion {
    private static let dotted = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)+(?:-[0-9A-Za-z.-]+)?)"#)
    private static let bare = try! NSRegularExpression(pattern: #"\b(\d+)\b"#)

    /// The first version in `--version` output: `gh version 2.96.0 (…)` →
    /// `2.96.0`, `go version go1.27.1 darwin/arm64` → `1.27.1`,
    /// `openjdk version "21" 2023-09-19` → `21` (dotted versions win over bare numbers).
    public static func parse(_ output: String) -> String? {
        let firstLines = output.split(whereSeparator: \.isNewline).prefix(3).joined(separator: "\n")
        for regex in [dotted, bare] {
            let range = NSRange(firstLines.startIndex..., in: firstLines)
            if let m = regex.firstMatch(in: firstLines, range: range), let r = Range(m.range(at: 1), in: firstLines) {
                return String(firstLines[r])
            }
        }
        return nil
    }

    struct Parsed: Equatable {
        var core: [Int]
        var pre: [String]
    }

    /// `v1.2.3-beta.1+build` → core [1,2,3], pre ["beta","1"]. Brew revisions
    /// (`3.14.4_1`) and cask build suffixes (`1.141.0,abc`) are dropped.
    static func normalize(_ raw: String) -> Parsed? {
        var s = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        if let comma = s.firstIndex(of: ",") { s = s[..<comma] }
        if let plus = s.firstIndex(of: "+") { s = s[..<plus] }
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            pre = s[s.index(after: dash)...].split(separator: ".").map(String.init)
            s = s[..<dash]
        }
        if let underscore = s.firstIndex(of: "_") { s = s[..<underscore] }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        var core: [Int] = []
        for p in parts {
            let digits = p.prefix { $0.isNumber }
            guard let n = Int(digits) else { return nil }
            core.append(n)
        }
        return core.isEmpty ? nil : Parsed(core: core, pre: pre)
    }

    /// -1 / 0 / 1, or nil when either side isn't a version. A prerelease sorts
    /// before its release (`2.0.0-rc.1` < `2.0.0`), as in semver.
    public static func compare(_ a: String, _ b: String) -> Int? {
        guard let x = normalize(a), let y = normalize(b) else { return nil }
        let n = max(x.core.count, y.core.count)
        for i in 0 ..< n {
            let l = i < x.core.count ? x.core[i] : 0, r = i < y.core.count ? y.core[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        switch (x.pre.isEmpty, y.pre.isEmpty) {
        case (true, true): return 0
        case (true, false): return 1
        case (false, true): return -1
        case (false, false): return comparePre(x.pre, y.pre)
        }
    }

    private static func comparePre(_ a: [String], _ b: [String]) -> Int {
        for (l, r) in zip(a, b) where l != r {
            switch (Int(l), Int(r)) {
            case let (li?, ri?): return li < ri ? -1 : 1
            case (.some, nil): return -1
            case (nil, .some): return 1
            case (nil, nil): return l < r ? -1 : 1
            }
        }
        return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
    }

    /// Newest first; unparseable strings sink to the end.
    public static func sortedDescending(_ versions: [String]) -> [String] {
        versions.sorted { a, b in
            guard let c = compare(a, b) else { return normalize(a) != nil }
            return c > 0
        }
    }

    public static func major(_ version: String) -> Int? { normalize(version)?.core.first }

    /// `3.14.8_2` → `3.14.8`: brew's revision suffix isn't the tool's version.
    public static func display(_ version: String) -> String {
        guard let r = version.range(of: #"_\d+$"#, options: .regularExpression) else { return version }
        return String(version[..<r.lowerBound])
    }
}
