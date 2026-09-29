import Foundation
import AgentsKitCore

/// The pool, the allowances and the record of switches, kept where the daemon can read
/// them (052, R6). On `LimitStore`'s pattern: a missing or unreadable file is the empty
/// value, so a daemon that cannot read its pool carries nothing anywhere rather than
/// refusing to work.
public struct AllowanceStore: Sendable {
    private let locations: StoreLocations

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    public func load() -> PoolSettings {
        guard let data = try? Data(contentsOf: locations.pool) else { return PoolSettings() }
        guard let pool = try? StoreCoding.decoder.decode(PoolSettings.self, from: data) else {
            StoreCoding.setAside(locations.pool)
            return PoolSettings()
        }
        let (kept, dropped) = pool.droppingKeysNotLent()
        if !dropped.isEmpty {
            DaemonLog.shared.write("pool: dropped entries on a key this Mac no longer lends: \(dropped.joined(separator: ", "))")
        }
        return kept
    }

    public func save(_ pool: PoolSettings) throws {
        try write(pool, to: locations.pool)
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

    /// One line per switch, appended. Lines that cannot be read are skipped rather than
    /// costing the rest.
    public func append(_ record: SwitchRecord) throws {
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        var line = try StoreCoding.encoder.encode(record)
        line.removeAll { $0 == UInt8(ascii: "\n") }
        line.append(UInt8(ascii: "\n"))
        if let handle = try? FileHandle(forWritingTo: locations.switches) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: locations.switches, options: .atomic)
        }
    }

    /// The switches since `cutoff`, oldest first. With `trim`, anything older is dropped
    /// from the file too (FR-025: kept 30 days).
    public func switches(since cutoff: Date, trim: Bool = false) -> [SwitchRecord] {
        guard let data = try? Data(contentsOf: locations.switches) else { return [] }
        let all = data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? StoreCoding.decoder.decode(SwitchRecord.self, from: Data($0))
        }
        let kept = all.filter { $0.at >= cutoff }
        if trim, kept.count < all.count {
            let lines = kept.compactMap { try? StoreCoding.encoder.encode($0) }
                .map { $0.filter { $0 != UInt8(ascii: "\n") } + [UInt8(ascii: "\n")] }
            try? Data(lines.joined()).write(to: locations.switches, options: .atomic)
        }
        return kept
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try StoreCoding.encoder.encode(value).write(to: url, options: .atomic)
    }
}
