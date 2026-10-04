import Foundation
import AgentsKitCore

/// `<root>/sandbox-settings.json` (064), kept as `ClientPermissionStore` keeps its file: a
/// missing file is every runtime as configured, and an unreadable one is set aside.
public struct SandboxSettingsStore: Sendable {
    private let root: URL
    private var file: URL { root.appendingPathComponent("sandbox-settings.json") }

    public init(locations: StoreLocations) { root = locations.root }

    public func load() -> SandboxSettings {
        return StoreFile.load(SandboxSettings.self, at: file, empty: .init(), meaning: "every runtime as configured")
    }

    public func save(_ settings: SandboxSettings) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try StoreFile.write(StoreCoding.encoder.encode(settings), to: file)
    }
}
