import Foundation
import Testing
@testable import AgentsKitCore

/// What both ends may rely on from a relay channel, pinned on the fake so the fake and
/// CloudKit keep the same rules (046, contracts/relay.md).
@Suite("The relay channel's rules")
struct RelayChannelContractTests {
    let device = UUID()
    let session = UUID()

    private func record(_ seq: Int64, _ direction: FrameDirection = .toMac, byte: UInt8 = 1,
                        sentAt: Date = Date()) -> FrameRecord {
        FrameRecord(session: session, direction: direction, seq: seq, sealed: Data([byte]), sentAt: sentAt)
    }

    @Test func postingTheSameFrameAgainReplacesIt() async throws {
        let cloud = FakeRelayCloud()
        let phone = FakeRelayChannel(cloud: cloud)
        try await phone.ensureZone(device: device)
        try await phone.post(record(0, byte: 1), device: device)
        try await phone.post(record(0, byte: 2), device: device)
        let stored = await cloud.stored(device: device)
        #expect(stored.count == 1)
        #expect(stored.first?.sealed == Data([2]))
    }

    @Test func eachEndFetchesOnlyWhatIsNewToIt() async throws {
        let cloud = FakeRelayCloud()
        let phone = FakeRelayChannel(cloud: cloud)
        let mac = FakeRelayChannel(cloud: cloud)
        try await phone.ensureZone(device: device)
        try await phone.post(record(0), device: device)
        #expect(try await mac.fetchChanges(device: device).map(\.seq) == [0])
        #expect(try await mac.fetchChanges(device: device).isEmpty)
        try await phone.post(record(1), device: device)
        #expect(try await mac.fetchChanges(device: device).map(\.seq) == [1])
        // The phone's own view is its own.
        #expect(try await phone.fetchChanges(device: device).map(\.seq) == [0, 1])
    }

    @Test func theMacHearsWhichZonesChanged() async throws {
        let cloud = FakeRelayCloud()
        let phone = FakeRelayChannel(cloud: cloud)
        let mac = FakeRelayChannel(cloud: cloud)
        try await phone.ensureZone(device: device)
        #expect(try await mac.changedDevices().isEmpty)
        try await phone.post(record(0), device: device)
        #expect(try await mac.changedDevices() == [device])
        #expect(try await mac.changedDevices().isEmpty)
    }

    @Test func deletedFramesAreGone() async throws {
        let cloud = FakeRelayCloud()
        let phone = FakeRelayChannel(cloud: cloud)
        try await phone.ensureZone(device: device)
        try await phone.post(record(0), device: device)
        try await phone.post(record(1), device: device)
        try await phone.delete([record(0).name], device: device)
        #expect(await cloud.stored(device: device).map(\.seq) == [1])
    }

    @Test func aSweepTakesOnlyTheOld() async throws {
        let cloud = FakeRelayCloud()
        let phone = FakeRelayChannel(cloud: cloud)
        try await phone.ensureZone(device: device)
        let now = Date()
        try await phone.post(record(0, sentAt: now.addingTimeInterval(-25 * 3600)), device: device)
        try await phone.post(record(1, sentAt: now), device: device)
        try await phone.sweep(olderThan: now.addingTimeInterval(-24 * 3600))
        #expect(await cloud.stored(device: device).map(\.seq) == [1])
    }

    @Test func aDeletedZoneSaysSo() async throws {
        let cloud = FakeRelayCloud()
        let phone = FakeRelayChannel(cloud: cloud)
        try await phone.ensureZone(device: device)
        try await phone.deleteZone(device: device)
        await #expect(throws: RelayChannelError.zoneGone) { try await phone.post(record(0), device: device) }
        await #expect(throws: RelayChannelError.zoneGone) { _ = try await phone.fetchChanges(device: device) }
    }

    @Test func aPauseIsAskedForOnce() async throws {
        let cloud = FakeRelayCloud()
        let phone = FakeRelayChannel(cloud: cloud)
        try await phone.ensureZone(device: device)
        await cloud.slowDown(4)
        await #expect(throws: RelayChannelError.slowDown(4)) { try await phone.post(record(0), device: device) }
        try await phone.post(record(0), device: device)
    }

    @Test func theNameIsSessionDirectionNumber() {
        #expect(record(12, .toDevice).name == "\(session.uuidString)/toDevice/12")
    }
}
