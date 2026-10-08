import Foundation
import AgentsKitCore

/// How long archived agents are kept, and the clock that counts it (051).
///
/// One small file, read whole and written whole, on `LimitStore`'s pattern. A missing
/// file is the defaults; an unreadable one is set aside and is the defaults. Deletion by age
/// is on by default, so a daemon that loses its file keeps deleting, and never starts
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
        return StoreFile.load(File.self, at: locations.retention, empty: File(), meaning: "retention at its defaults")
    }

    public func save(_ file: File) throws {
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try StoreFile.write(StoreCoding.encoder.encode(file), to: locations.retention)
    }
}
