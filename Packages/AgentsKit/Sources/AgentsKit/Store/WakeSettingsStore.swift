import Foundation
import AgentsKitCore

/// The switch and the grace, as `wake.json` (beside retention).
///
/// One small file, read whole and written whole. A missing file is the default, on
/// for one hour. An unreadable one is set aside and is the default too: a bad read
/// must not quietly stop holding the Mac awake.
public struct WakeSettingsStore: Sendable {
    private let locations: StoreLocations

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    public func load() -> WakeSettings {
        guard let data = try? Data(contentsOf: locations.wakeSettings) else { return WakeSettings() }
        guard let settings = try? StoreCoding.decoder.decode(WakeSettings.self, from: data) else {
            StoreCoding.setAside(locations.wakeSettings)
            return WakeSettings()
        }
        return settings
    }

    public func save(_ settings: WakeSettings) throws {
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try StoreCoding.encoder.encode(settings).write(to: locations.wakeSettings, options: .atomic)
    }
}
