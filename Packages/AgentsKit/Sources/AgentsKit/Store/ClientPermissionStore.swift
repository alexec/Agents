import Foundation
import AgentsKitCore

public struct ClientPermissionStore: Sendable {
    private let root: URL
    private var file: URL { root.appendingPathComponent("client-permissions.json") }

    public init(locations: StoreLocations) { root = locations.root }

    public func load() -> ClientPermissionSettings {
        return StoreFile.load(ClientPermissionSettings.self, at: file, empty: .init(), meaning: "every runtime asks")
    }

    public func save(_ settings: ClientPermissionSettings) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try StoreFile.write(StoreCoding.encoder.encode(settings), to: file)
    }
}
