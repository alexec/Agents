import AgentsKitCore
import Foundation

/// `display.json` in the person's settings (#1033): the display choices every client shares.
/// One small map, read whole and written whole. A missing file is every choice at its
/// default; an unreadable one is set aside and is the same.
public struct DisplayPreferencesStore: Sendable {
    private let file: URL

    public init(locations: StoreLocations) { file = locations.displayPreferences }

    public func load() -> DaemonAPI.DisplayPreferences {
        StoreFile.load(DaemonAPI.DisplayPreferences.self, at: file, empty: [:], meaning: "every display choice at its default")
    }

    /// Each key given replaces its value, and `null` removes it. Answers the whole map.
    public func merge(_ changes: DaemonAPI.DisplayPreferences) throws -> DaemonAPI.DisplayPreferences {
        var all = load()
        for (key, value) in changes {
            if value == .null { all[key] = nil } else { all[key] = value }
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try StoreFile.write(StoreCoding.encoder.encode(all), to: file)
        return all
    }
}
