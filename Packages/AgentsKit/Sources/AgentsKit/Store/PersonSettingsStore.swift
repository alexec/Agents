import AgentsKitCore
import Foundation

/// What agents call the person (#121), in `person.json` in the person's settings (#1033).
public struct PersonSettingsStore: Sendable {
    private let file: URL

    public init(locations: StoreLocations) { file = locations.person }

    public func load() -> PersonSettings {
        return StoreFile.load(PersonSettings.self, at: file, empty: .init(), meaning: "every setting at its default")
    }

    public func save(_ settings: PersonSettings) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try StoreFile.write(StoreCoding.encoder.encode(settings), to: file)
    }
}
