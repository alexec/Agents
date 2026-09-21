import AgentsKitCore
import Foundation

/// Where the paired devices are kept: `devices.json` under the daemon's root, beside
/// `projects.json`, read whole and written whole on change.
///
/// The one thing feature 021 writes to disk. **The daemon is the only writer**; the
/// bridge reads nothing from here and is handed what to send. A missing or unreadable
/// file is no devices, which is the safe reading: nothing is routed to a device that
/// cannot be shown to have been approved.
public struct DeviceStore: Sendable {
    private let locations: StoreLocations

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    public func load() -> [Device] {
        guard let data = try? Data(contentsOf: locations.devices) else { return [] }
        guard let devices = try? StoreCoding.decoder.decode([Device].self, from: data) else {
            return []
        }
        // One id is one device. A file that somehow holds two records for one id keeps
        // the first rather than showing both.
        var seen: Set<UUID> = []
        return devices.filter { seen.insert($0.id).inserted }
    }

    public func save(_ devices: [Device]) throws {
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        let ordered = devices.sorted { $0.announcedAt < $1.announcedAt }
        let data = try StoreCoding.encoder.encode(ordered)
        try data.write(to: locations.devices, options: .atomic)
    }
}
