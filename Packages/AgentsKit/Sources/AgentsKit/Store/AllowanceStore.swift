import Foundation
import AgentsKitCore

/// Each runtime's allowance state, kept where the daemon can read it (052, R6; 065). On
/// `LimitStore`'s pattern: a missing or unreadable file is the empty value. The pool's
/// own `pool.json` and `switches.jsonl` are no longer read or written, and are left on
/// disk.
public struct AllowanceStore: Sendable {
    private let locations: StoreLocations

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    public func loadAllowances() -> [AllowanceState] {
        guard let data = try? Data(contentsOf: locations.allowances) else { return [] }
        guard let states = try? StoreCoding.decoder.decode([AllowanceState].self, from: data) else {
            StoreCoding.setAside(locations.allowances)
            return []
        }
        return states
    }

    public func saveAllowances(_ states: [AllowanceState]) throws {
        try write(states, to: locations.allowances)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try StoreCoding.encoder.encode(value).write(to: url, options: .atomic)
    }
}
