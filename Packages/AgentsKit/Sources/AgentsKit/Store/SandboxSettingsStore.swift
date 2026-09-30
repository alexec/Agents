import Foundation
import AgentsKitCore

/// `<root>/sandbox-settings.json` (064), kept as `ClientPermissionStore` keeps its file: a
/// missing file is every runtime as configured, and an unreadable one is set aside.
public struct SandboxSettingsStore: Sendable {
    private let root: URL
    private var file: URL { root.appendingPathComponent("sandbox-settings.json") }

    public init(locations: StoreLocations) { root = locations.root }

    public func load() -> SandboxSettings {
        guard let data = try? Data(contentsOf: file) else { return .init() }
        guard let settings = try? StoreCoding.decoder.decode(SandboxSettings.self, from: data) else {
            StoreCoding.setAside(file)
            return .init()
        }
        return settings
    }

    public func save(_ settings: SandboxSettings) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try StoreCoding.encoder.encode(settings).write(to: file, options: .atomic)
    }
}
