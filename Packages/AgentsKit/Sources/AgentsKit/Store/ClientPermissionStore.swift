import Foundation
import AgentsKitCore

public struct ClientPermissionStore: Sendable {
    private let file: URL

    public init(locations: StoreLocations) { file = locations.clientPermissions }

    public func load() -> ClientPermissionSettings {
        return StoreFile.load(ClientPermissionSettings.self, at: file, empty: .init(), meaning: "every runtime asks")
    }

    public func save(_ settings: ClientPermissionSettings) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try StoreFile.write(StoreCoding.encoder.encode(settings), to: file)
    }
}
