import AgentsKitCore
import Foundation

/// What agents call the person (#121), in `person.json` beside the other settings.
public struct PersonSettingsStore: Sendable {
    private let root: URL
    private var file: URL { root.appendingPathComponent("person.json") }

    public init(locations: StoreLocations) { root = locations.root }

    public func load() -> PersonSettings {
        return StoreFile.load(PersonSettings.self, at: file, empty: .init(), meaning: "every setting at its default")
    }

    public func save(_ settings: PersonSettings) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try StoreFile.write(StoreCoding.encoder.encode(settings), to: file)
    }
}
