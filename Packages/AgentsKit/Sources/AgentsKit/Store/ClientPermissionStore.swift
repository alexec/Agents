import Foundation
import AgentsKitCore

public struct ClientPermissionStore: Sendable {
    private let root: URL
    private var file: URL { root.appendingPathComponent("client-permissions.json") }

    public init(locations: StoreLocations) { root = locations.root }

    public func load() -> ClientPermissionSettings {
        guard let data = try? Data(contentsOf: file) else { return .init() }
        guard let settings = try? StoreCoding.decoder.decode(ClientPermissionSettings.self, from: data) else {
            StoreCoding.setAside(file)
            DaemonLog.shared.write("client-permissions.json could not be read; set aside, every runtime asks")
            return .init()
        }
        return settings
    }

    public func save(_ settings: ClientPermissionSettings) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try StoreCoding.encoder.encode(settings).write(to: file, options: .atomic)
    }
}
