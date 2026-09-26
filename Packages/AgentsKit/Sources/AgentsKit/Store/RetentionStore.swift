import Foundation
import AgentsKitCore

/// How long archived agents are kept, and the clock that counts it (051).
///
/// One small file, read whole and written whole, on `LimitStore`'s pattern. A missing
/// file is the defaults; an unreadable one is set aside and is the defaults. Retirement
/// is on by default, so a daemon that loses its file keeps retiring, and never starts
/// keeping everything for ever because of a bad read.
public struct RetentionStore: Sendable {
    public struct File: Codable, Hashable, Sendable {
        public var settings = RetentionSettings()
        public var clock = RetentionClock()

        public init(settings: RetentionSettings = RetentionSettings(), clock: RetentionClock = RetentionClock()) {
            self.settings = settings
            self.clock = clock
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            settings = (try? c.decode(RetentionSettings.self, forKey: .settings)) ?? RetentionSettings()
            clock = (try? c.decode(RetentionClock.self, forKey: .clock)) ?? RetentionClock()
        }
    }

    private let locations: StoreLocations

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    public func load() -> File {
        guard let data = try? Data(contentsOf: locations.retention) else { return File() }
        guard let file = try? StoreCoding.decoder.decode(File.self, from: data) else {
            StoreCoding.setAside(locations.retention)
            return File()
        }
        return file
    }

    public func save(_ file: File) throws {
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try StoreCoding.encoder.encode(file).write(to: locations.retention, options: .atomic)
    }
}
