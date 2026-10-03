import AgentsKitCore
import Foundation

/// What agents call the person (#121), in `person.json` beside the other settings.
public struct PersonSettingsStore: Sendable {
    private let root: URL
    private var file: URL { root.appendingPathComponent("person.json") }

    public init(locations: StoreLocations) { root = locations.root }

    public func load() -> PersonSettings {
        guard let data = try? Data(contentsOf: file) else { return .init() }
        guard let settings = try? StoreCoding.decoder.decode(PersonSettings.self, from: data) else {
            StoreCoding.setAside(file)
            return .init()
        }
        return settings
    }

    public func save(_ settings: PersonSettings) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try StoreCoding.encoder.encode(settings).write(to: file, options: .atomic)
    }
}
