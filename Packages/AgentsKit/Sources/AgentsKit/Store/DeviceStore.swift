import AgentsKitCore
import Foundation

/// Where the paired devices are kept: `devices.json` under the daemon's root, beside
/// `projects.json`, read whole and written whole on change.
///
/// The one thing feature 021 writes to disk. **The daemon is the only writer**; the
/// bridge reads nothing from here and is handed what to send. A missing file is no
/// devices, which is the safe reading: nothing is routed to, or sealed to, a device whose
/// key is not on record. One that cannot be read is set aside rather than written over
/// on the next announce (#171), and one bad record costs that record only.
public struct DeviceStore: Sendable {
    private let locations: StoreLocations

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    public func load() -> [Device] {
        let devices = StoreFile.loadList(Device.self, at: locations.devices, meaning: "starting with no paired devices")
        // One id is one device. A file that somehow holds two records for one id keeps
        // the first rather than showing both.
        var seen: Set<UUID> = []
        return devices.filter { seen.insert($0.id).inserted }
    }

    public func save(_ devices: [Device]) throws {
        let ordered = devices.sorted { $0.announcedAt < $1.announcedAt }
        try StoreFile.write(try StoreCoding.encoder.encode(ordered), to: locations.devices)
    }
}
