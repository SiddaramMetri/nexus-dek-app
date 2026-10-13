import Foundation

public enum ThemeMode: String, Codable, CaseIterable, Sendable { case system, light, dark }
public enum CardLayout: String, Codable, CaseIterable, Sendable { case grid, list }
public enum QuitBehavior: String, Codable, CaseIterable, Sendable { case stopUnlinked, keepAll }

/// Feature modules. Order is nav order.
public enum ModuleID: String, Codable, CaseIterable, Sendable { case homebrew, ports, doctor, claude }

/// Persisted user settings — same keys as the Tauri `settings.json`.
public struct AppSettings: Codable, Equatable, Sendable {
    public var theme: ThemeMode = .system
    public var layout: CardLayout = .grid
    public var pollIntervalMs: Int = 4000
    public var quitBehavior: QuitBehavior = .stopUnlinked
    /// User drag-reorder of service cards, by formula.
    public var cardOrder: [String] = []
    /// nil = never chosen → the first-run picker decides.
    public var enabledModules: [ModuleID]? = nil
    public var autoArchiveEnabled = false
    public var autoArchiveCutoffDays = 30
    public var autoVacuumEnabled = false
    /// Notify when the startup disk drops under 10 GB free.
    public var lowDiskWarning = true

    public init() {}

    enum CodingKeys: String, CodingKey {
        case theme, layout, pollIntervalMs, quitBehavior, cardOrder, enabledModules
        case autoArchiveEnabled, autoArchiveCutoffDays, autoVacuumEnabled, lowDiskWarning
    }

    /// Lenient: the file is user-editable, so every field falls back to its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        theme = (try? c.decode(ThemeMode.self, forKey: .theme)) ?? d.theme
        layout = (try? c.decode(CardLayout.self, forKey: .layout)) ?? d.layout
        pollIntervalMs = (try? c.decode(Int.self, forKey: .pollIntervalMs)).map { max(1000, $0) } ?? d.pollIntervalMs
        quitBehavior = (try? c.decode(QuitBehavior.self, forKey: .quitBehavior)) ?? d.quitBehavior
        cardOrder = (try? c.decode([String].self, forKey: .cardOrder)) ?? d.cardOrder
        enabledModules = Self.sanitizeModules((try? c.decode([String].self, forKey: .enabledModules)))
        autoArchiveEnabled = (try? c.decode(Bool.self, forKey: .autoArchiveEnabled)) ?? d.autoArchiveEnabled
        autoArchiveCutoffDays = (try? c.decode(Int.self, forKey: .autoArchiveCutoffDays)) ?? d.autoArchiveCutoffDays
        autoVacuumEnabled = (try? c.decode(Bool.self, forKey: .autoVacuumEnabled)) ?? d.autoVacuumEnabled
        lowDiskWarning = (try? c.decode(Bool.self, forKey: .lowDiskWarning)) ?? d.lowDiskWarning
    }

    /// Unknown ids dropped; an empty result is corruption → nil (fail open, never a dead app).
    static func sanitizeModules(_ raw: [String]?) -> [ModuleID]? {
        guard let raw else { return nil }
        let ids = ModuleID.allCases.filter { raw.contains($0.rawValue) }
        return ids.isEmpty ? nil : ids
    }

    /// Opt-out: a module is on unless the user chose a list without it.
    public func isEnabled(_ m: ModuleID) -> Bool { enabledModules?.contains(m) ?? true }
}

public enum LinkState: String, Codable, Sendable { case linked, unlinked }

public struct ManagedService: Codable, Equatable, Hashable, Sendable {
    public var formula: String
    public var displayName: String
    public init(formula: String, displayName: String) {
        self.formula = formula
        self.displayName = displayName
    }
}

/// Curated services + per-formula link intent — Tauri `services.json` / `serviceIntent`.
public struct ServiceIntent: Codable, Equatable, Sendable {
    public var managed: [ManagedService] = []
    public var intent: [String: LinkState] = [:]
    public var seeded = false
    public init() {}

    enum CodingKeys: String, CodingKey { case managed, intent, seeded }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        managed = (try? c.decode([ManagedService].self, forKey: .managed)) ?? []
        intent = (try? c.decode([String: LinkState].self, forKey: .intent)) ?? [:]
        seeded = (try? c.decode(Bool.self, forKey: .seeded)) ?? false
    }
}

/// One run of a service. `endMs` nil = still running.
public struct Run: Codable, Equatable, Sendable {
    public var startMs: Double
    public var endMs: Double?
    public init(startMs: Double, endMs: Double?) {
        self.startMs = startMs
        self.endMs = endMs
    }
}

public enum Stores {
    public static let settings = JSONStore<AppSettings>(file: "settings.json", key: "settings")
    public static let serviceIntent = JSONStore<ServiceIntent>(file: "services.json", key: "serviceIntent")
    public static let sessions = JSONStore<[String: [Run]]>(file: "sessions.json", key: "runs")
}
