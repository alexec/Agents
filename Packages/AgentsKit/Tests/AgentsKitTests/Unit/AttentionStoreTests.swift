import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// `attention.json`: what the daemon has already told somebody about.
///
/// The store itself is deliberately dumb — read the file, write the file — and every
/// rule about what may be *acted* on lives in `pruned(knownDevices:now:)`, which is pure
/// and is tested here without a daemon anywhere near it.
@Suite("Attention store")
struct AttentionStoreTests {
    private func temporary() -> StoreLocations {
        StoreLocations(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsAttentionStore-\(UUID().uuidString)", isDirectory: true))
    }

    private func records() -> (AttentionRecords, NeedID, NeedID, UUID) {
        let phone = UUID()
        let question = NeedID.permission(UUID())
        let report = NeedID.report(UUID(), Date(timeIntervalSince1970: 1_700_000_000))
        let records = AttentionRecords(
            raised: [RaisedNote(need: question, at: Date(timeIntervalSince1970: 1_700_000_100)),
                     RaisedNote(need: report, at: Date(timeIntervalSince1970: 1_700_000_200))],
            deliveries: [Delivery(needID: question, to: .device(phone),
                                  alertedAt: Date(timeIntervalSince1970: 1_700_000_150), alertCount: 2),
                         Delivery(needID: report, to: .mac,
                                  alertedAt: Date(timeIntervalSince1970: 1_700_000_250), alertCount: 1)],
            withdrawing: [PendingWithdrawal(need: .elicitation(UUID()), device: phone,
                                            decidedAt: Date(timeIntervalSince1970: 1_700_000_300))])
        return (records, question, report, phone)
    }

    // MARK: Round trip

    /// Everything written comes back, including the two tagged enums — `NeedID` and
    /// `Surface` — that are the reason this file is worth a test at all.
    @Test func everythingWrittenComesBack() throws {
        let locations = temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = AttentionStore(locations: locations)
        let (written, question, report, phone) = records()

        store.save(written)
        let read = store.load()

        #expect(read == written)
        #expect(read.raised.first(where: { $0.need == question })?.at
                == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(read.deliveries.first(where: { $0.needID == question })?.to == .device(phone))
        #expect(read.deliveries.first(where: { $0.needID == report })?.to == .mac)
        #expect(read.deliveries.first(where: { $0.needID == question })?.alertCount == 2)
    }

    /// It is meant to be read with `cat`, like every other file beside it.
    @Test func itIsReadableByAPerson() throws {
        let locations = temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = AttentionStore(locations: locations)
        store.save(records().0)

        let text = try String(contentsOf: locations.attention, encoding: .utf8)
        #expect(text.contains("deliveries"))
        #expect(text.contains("permission"))
        #expect(text.contains("mac"))
    }

    /// What must never be in it: anything about what a need *says*. A second copy of a
    /// headline here would be the one thing 021's FR-001 forbids.
    @Test func itHoldsNothingAboutWhatTheNeedSays() throws {
        let locations = temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let store = AttentionStore(locations: locations)
        store.save(records().0)

        let text = try String(contentsOf: locations.attention, encoding: .utf8)
        for word in ["headline", "h1", "h2", "h3", "title", "kind", "folder"] {
            #expect(!text.contains(word), "\(word) has no business in attention.json")
        }
    }

    // MARK: Losing it costs nothing but a repeated notification

    @Test func aMissingFileIsNoNotes() {
        let locations = temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        #expect(AttentionStore(locations: locations).load() == AttentionRecords())
    }

    @Test func anUnreadableFileIsNoNotes() throws {
        let locations = temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: locations.attention)

        #expect(AttentionStore(locations: locations).load() == AttentionRecords())
    }

    /// One bad entry costs that entry, not the file. The same rule `Lossy` already
    /// gives the project list.
    @Test func oneBadEntryCostsThatEntryAndNoOther() throws {
        let locations = temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        let good = UUID()
        let text = """
            {"deliveries":[\
            {"needID":{"nonsense":"what"},"alertedAt":"2026-09-24T10:00:00.000Z","alertCount":1},\
            {"needID":{"permission":"\(good.uuidString)"},"to":{"mac":{}},\
            "alertedAt":"2026-09-24T10:00:00.000Z","alertCount":1}\
            ],"raised":[],"withdrawing":[]}
            """
        try Data(text.utf8).write(to: locations.attention)

        let read = AttentionStore(locations: locations).load()
        #expect(read.deliveries.map(\.needID) == [.permission(good)],
                "the readable one survives its neighbour")
    }

    // MARK: What may be acted on

    /// FR-006: a note naming a device this daemon does not know is dropped. Nothing is
    /// sealed to, or withdrawn from, a device that is not on record.
    @Test func aNoteForAnUnknownDeviceIsDropped() {
        let known = UUID(), forgotten = UUID()
        let kept = NeedID.permission(UUID()), lost = NeedID.permission(UUID())
        let now = Date()
        let records = AttentionRecords(
            raised: [RaisedNote(need: kept, at: now), RaisedNote(need: lost, at: now)],
            deliveries: [Delivery(needID: kept, to: .device(known), alertedAt: now, alertCount: 1),
                         Delivery(needID: lost, to: .device(forgotten), alertedAt: now, alertCount: 1)],
            withdrawing: [PendingWithdrawal(need: .report(UUID(), now), device: forgotten, decidedAt: now)])

        let pruned = records.pruned(knownDevices: [known], now: now)

        #expect(pruned.deliveries.map(\.needID) == [kept])
        #expect(pruned.withdrawing.isEmpty)
        #expect(pruned.raised.count == 2, "a raising is not about a device and is not dropped with one")
    }

    /// A delivery to the Mac survives whatever the device list says: the Mac is not a
    /// device and is never in it.
    @Test func aDeliveryToTheMacIsNeverDroppedForWantOfADevice() {
        let need = NeedID.permission(UUID())
        let now = Date()
        let records = AttentionRecords(
            raised: [RaisedNote(need: need, at: now)],
            deliveries: [Delivery(needID: need, to: .mac, alertedAt: now, alertCount: 1)])

        #expect(records.pruned(knownDevices: [], now: now).deliveries.count == 1)
    }

    /// A delivery showing nowhere — watched, or nobody reachable — is still a record
    /// that the person has been alerted, and is kept.
    @Test func aDeliveryShowingNowhereIsKept() {
        let need = NeedID.permission(UUID())
        let now = Date()
        let records = AttentionRecords(
            deliveries: [Delivery(needID: need, to: nil, alertedAt: now, alertCount: 3)])

        #expect(records.pruned(knownDevices: [], now: now).deliveries.count == 1)
    }

    /// A retry, not a queue. Seven days and it goes.
    @Test func aWithdrawalOlderThanTheHorizonIsDropped() {
        let phone = UUID()
        let now = Date()
        let fresh = PendingWithdrawal(need: .permission(UUID()), device: phone,
                                      decidedAt: now.addingTimeInterval(-60 * 60))
        let stale = PendingWithdrawal(need: .permission(UUID()), device: phone,
                                      decidedAt: now.addingTimeInterval(-AttentionRecords.withdrawalHorizon - 1))
        let records = AttentionRecords(withdrawing: [fresh, stale])

        let pruned = records.pruned(knownDevices: [phone], now: now)

        #expect(pruned.withdrawing == [fresh])
    }

    /// Pruning nothing is not a write. The daemon compares before it saves, and a
    /// prune that invents a difference would make it save on every pass.
    @Test func pruningChangesNothingWhenThereIsNothingToDrop() {
        let (records, _, _, phone) = self.records()
        #expect(records.pruned(knownDevices: [phone], now: Date(timeIntervalSince1970: 1_700_000_400))
                == records)
    }
}
