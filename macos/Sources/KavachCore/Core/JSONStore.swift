import Foundation

/// A small JSON file in the app-data dir holding one top-level key — the same
/// shape `tauri-plugin-store` wrote (`{"settings": {...}}`), so existing files
/// load as-is.
public struct JSONStore<Value: Codable>: Sendable {
    public let file: String
    public let key: String

    public init(file: String, key: String) {
        self.file = file
        self.key = key
    }

    var url: URL { Paths.appData.appendingPathComponent(file) }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let inner = obj[key],
              let innerData = try? JSONSerialization.data(withJSONObject: inner) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: innerData)
    }

    /// Atomic write; other top-level keys in the file are preserved.
    public func save(_ value: Value) {
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            obj = existing
        }
        guard let encoded = try? JSONEncoder().encode(value),
              let inner = try? JSONSerialization.jsonObject(with: encoded) else { return }
        obj[key] = inner
        guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: Paths.appData, withIntermediateDirectories: true)
        try? out.write(to: url, options: .atomic)
    }
}
