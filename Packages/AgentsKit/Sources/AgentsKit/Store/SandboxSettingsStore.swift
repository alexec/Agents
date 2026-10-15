import Foundation
import AgentsKitCore

/// `sandbox.json` in the person's settings (064, #1033), kept as `ClientPermissionStore` keeps its file: a
/// missing file is every runtime as configured, and an unreadable one is set aside.
public struct SandboxSettingsStore: Sendable {
    private let file: URL

    public init(locations: StoreLocations) { file = locations.sandbox }

    public func load() -> SandboxSettings {
        return StoreFile.load(SandboxSettings.self, at: file, empty: .init(), meaning: "every runtime as configured")
    }

    public func save(_ settings: SandboxSettings) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try StoreFile.write(StoreCoding.encoder.encode(settings), to: file)
    }
}
