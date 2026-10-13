import Foundation

/// The app's identity, read from the bundle's Info.plist — which the build
/// script fills from `Support/app.env`, the single place to rename the app.
/// The fallbacks only apply when running unbundled (tests, `swift run`) and
/// must mirror app.env.
public enum AppInfo {
    private static let info = Bundle.main.infoDictionary ?? [:]
    /// True inside the real .app (not the test runner or a bare binary).
    private static let bundled = (info["AppShortName"] as? String) != nil

    private static func value(_ key: String, _ fallback: String) -> String {
        bundled ? (info[key] as? String ?? fallback) : fallback
    }

    /// "Kavach Console"
    public static let name = value("CFBundleDisplayName", "Kavach Console")
    /// "Kavach" — used inside sentences ("while Kavach runs").
    public static let shortName = value("AppShortName", "Kavach")
    public static let tagline = value("AppTagline", "Armour for your Mac")
    /// Also names the data folder in Application Support.
    public static let bundleID = bundled ? (Bundle.main.bundleIdentifier ?? "com.vss.kavachconsole") : "com.vss.kavachconsole"
}
