import Foundation
import AgentsKitCore

/// The two limits the reader set, kept where the daemon can read them.
///
/// One file, read whole and written whole, on the pattern `ProjectStore` already
/// follows. There are two facts in it and both belong to the person.
///
/// A missing or unreadable file is an empty `CostLimits` — no limit. A daemon that
/// cannot read its own limits must not refuse to work, and it must not invent a limit
/// nobody set: both failures are worse than the thing the file is for.
public struct LimitStore: Sendable {
    private let locations: StoreLocations

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    public func load() -> CostLimits {
        return StoreFile.load(CostLimits.self, at: locations.limits, empty: CostLimits(), meaning: "no spending limits set")
    }

    public func save(_ limits: CostLimits) throws {
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        let data = try StoreCoding.encoder.encode(limits)
        try StoreFile.write(data, to: locations.limits)
    }
}
