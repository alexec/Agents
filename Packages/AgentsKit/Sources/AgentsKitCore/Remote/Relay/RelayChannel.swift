// Not on Linux: the server build of agentsd has no relay (037, 046).
#if canImport(CryptoKit)
import Foundation

/// One sealed frame as it sits in a device's zone (046, data-model.md § Frame).
///
/// Everything here but `sealed` is ids, numbers and a date: what is readable in the
/// person's iCloud is which session, which way, which number and when, and nothing about
/// the work (SC-005).
public struct FrameRecord: Sendable, Hashable {
    public var session: UUID
    public var direction: FrameDirection
    public var seq: Int64
    public var sealed: Data
    public var sentAt: Date

    public init(session: UUID, direction: FrameDirection, seq: Int64, sealed: Data, sentAt: Date = Date()) {
        self.session = session
        self.direction = direction
        self.seq = seq
        self.sealed = sealed
        self.sentAt = sentAt
    }

    /// `<session>/<direction>/<seq>`, so a save retried after a timeout replaces the
    /// frame it already wrote rather than adding a second copy.
    public var name: String {
        "\(session.uuidString)/\(direction == .toMac ? "toMac" : "toDevice")/\(seq)"
    }
}

public enum RelayChannelError: Error, Sendable, Equatable {
    /// iCloud asked for a pause of this many seconds before the next try (FR-018).
    case slowDown(TimeInterval)
    /// The device's zone is not there: never made, or deleted because the Mac forgot
    /// the device (R11).
    case zoneGone
    /// The person's iCloud is full.
    case full
    /// No iCloud account on this device, or it is restricted.
    case noAccount
}

/// Where relayed frames are kept between the two ends: one zone per device (046, R5).
///
/// The real one is `CloudKitRelayChannel`; the fake is what every test runs against,
/// because the properties under test — order, once only, nothing legible, refusal — are
/// about what the two ends do with frames, never about how CloudKit stores them. Each end
/// holds its own channel, with its own idea of what it has already fetched.
public protocol RelayChannel: Sendable {
    /// Make the device's zone. Safe to call again.
    func ensureZone(device: UUID) async throws
    func post(_ record: FrameRecord, device: UUID) async throws
    /// The records in the device's zone that this channel has not returned before.
    func fetchChanges(device: UUID) async throws -> [FrameRecord]
    /// The devices whose zones have changed since this channel last asked. The Mac's side.
    func changedDevices() async throws -> [UUID]
    func delete(_ names: [String], device: UUID) async throws
    func deleteZone(device: UUID) async throws
    /// Remove every frame older than `date`, in every zone. The Mac's side (FR-017).
    func sweep(olderThan date: Date) async throws
}

/// The fake store behind any number of `FakeRelayChannel`s — iCloud, for a test.
///
/// It can be told to misbehave the ways iCloud is allowed to: hand frames back in the
/// wrong order, hand one back twice, hold them back for a few fetches, or ask for a pause.
public actor FakeRelayCloud {
    struct Stored {
        var order: Int
        var record: FrameRecord
    }

    private var zones: [UUID: [String: Stored]] = [:]
    private var counter = 0
    public private(set) var posts = 0
    public private(set) var postTimes: [Date] = []

    /// Every fetch returns its records last-first.
    public var reverses = false
    /// Every fetch also returns the record it returned the time before.
    public var repeats = false
    /// Records are not returned until this many fetches after they were posted.
    public var holdsBackFetches = 0
    /// The next call throws `.slowDown(seconds)`.
    public var slowDownNext: TimeInterval?

    public init() {}

    public func behave(reverses: Bool = false, repeats: Bool = false, holdsBackFetches: Int = 0) {
        self.reverses = reverses
        self.repeats = repeats
        self.holdsBackFetches = holdsBackFetches
    }

    public func slowDown(_ seconds: TimeInterval) { slowDownNext = seconds }

    func check() throws {
        if let seconds = slowDownNext {
            slowDownNext = nil
            throw RelayChannelError.slowDown(seconds)
        }
    }

    func ensureZone(_ device: UUID) throws {
        try check()
        if zones[device] == nil { zones[device] = [:] }
    }

    func post(_ record: FrameRecord, _ device: UUID) throws {
        try check()
        guard zones[device] != nil else { throw RelayChannelError.zoneGone }
        counter += 1
        posts += 1
        postTimes.append(record.sentAt)
        zones[device]?[record.name] = Stored(order: counter, record: record)
    }

    /// What is past `cursor` in a zone, and the new cursor.
    func records(_ device: UUID, after cursor: Int, fetchesSincePost: (Int) -> Bool) throws -> ([FrameRecord], Int) {
        try check()
        guard let zone = zones[device] else { throw RelayChannelError.zoneGone }
        let fresh = zone.values.filter { $0.order > cursor && fetchesSincePost($0.order) }.sorted { $0.order < $1.order }
        let last = fresh.last?.order ?? cursor
        var out = fresh.map(\.record)
        if repeats, let previous = zone.values.filter({ $0.order == cursor }).first { out.insert(previous.record, at: 0) }
        if reverses { out.reverse() }
        return (out, last)
    }

    func latestOrder(_ device: UUID) -> Int {
        zones[device]?.values.map(\.order).max() ?? 0
    }

    var devices: [UUID] { Array(zones.keys) }

    func delete(_ names: [String], _ device: UUID) throws {
        try check()
        for name in names { zones[device]?.removeValue(forKey: name) }
    }

    func deleteZone(_ device: UUID) {
        zones.removeValue(forKey: device)
    }

    func sweep(olderThan date: Date) {
        for device in zones.keys {
            zones[device] = zones[device]?.filter { $0.value.record.sentAt >= date }
        }
    }

    /// Everything in a zone, for a test to look at.
    public func stored(device: UUID) -> [FrameRecord] {
        (zones[device]?.values.sorted { $0.order < $1.order } ?? []).map(\.record)
    }

    public func hasZone(_ device: UUID) -> Bool { zones[device] != nil }
}

/// One end's view of a `FakeRelayCloud`.
public actor FakeRelayChannel: RelayChannel {
    public let cloud: FakeRelayCloud
    private var cursors: [UUID: Int] = [:]
    private var seenOrders: [UUID: Int] = [:]
    private var fetches = 0
    private var postedAtFetch: [Int: Int] = [:]

    public init(cloud: FakeRelayCloud) {
        self.cloud = cloud
    }

    public func ensureZone(device: UUID) async throws { try await cloud.ensureZone(device) }

    public func post(_ record: FrameRecord, device: UUID) async throws { try await cloud.post(record, device) }

    public func fetchChanges(device: UUID) async throws -> [FrameRecord] {
        fetches += 1
        let hold = await cloud.holdsBackFetches
        let now = fetches
        // An order is first seen by some fetch; it is returned only `hold` fetches later.
        let latest = await cloud.latestOrder(device)
        let cursor = cursors[device] ?? 0
        for order in stride(from: cursor + 1, through: max(cursor, latest), by: 1) where postedAtFetch[order] == nil {
            postedAtFetch[order] = now
        }
        let seen = postedAtFetch
        let (records, last) = try await cloud.records(device, after: cursor) { order in
            (seen[order] ?? now) + hold <= now
        }
        cursors[device] = last
        return records
    }

    public func changedDevices() async throws -> [UUID] {
        var changed: [UUID] = []
        for device in await cloud.devices {
            let latest = await cloud.latestOrder(device)
            if latest > (seenOrders[device] ?? 0) {
                seenOrders[device] = latest
                changed.append(device)
            }
        }
        return changed
    }

    public func delete(_ names: [String], device: UUID) async throws { try await cloud.delete(names, device) }

    public func deleteZone(device: UUID) async throws { await cloud.deleteZone(device) }

    public func sweep(olderThan date: Date) async throws { await cloud.sweep(olderThan: date) }
}
#endif
