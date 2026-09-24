import AgentsKitCore
import Foundation

/// When a need was first raised, and who has already been told about it.
///
/// One entry per need the daemon currently believes outstanding. Removed the moment the
/// need is met, which is what makes a question asked again later a *new* need with a new
/// time rather than the old one warmed over.
public struct RaisedNote: Codable, Hashable, Sendable {
    public var need: NeedID
    public var at: Date

    public init(need: NeedID, at: Date) {
        self.need = need
        self.at = at
    }
}

/// A banner that has to come down, on a device that could not be told at the time.
///
/// Kept because a withdrawal is the one post with no second chance. Every other
/// `mailbox/post` is repeated by the daemon's next decision about that need; this one is
/// *about* the need being over, so there is no next decision — if it is lost while the
/// bridge is reconnecting, the phone keeps a question nobody can answer.
///
/// Acted on in US2. Declared and round-tripped from US1 so that a file written by a build
/// which has US2 is not quietly emptied by one which does not.
public struct PendingWithdrawal: Codable, Hashable, Sendable {
    public var need: NeedID
    public var device: UUID
    public var decidedAt: Date

    public init(need: NeedID, device: UUID, decidedAt: Date) {
        self.need = need
        self.device = device
        self.decidedAt = decidedAt
    }
}

/// The whole of `attention.json`.
///
/// It holds **nothing about what a need says** — no headline, no title, no tool name.
/// `Need` is derived from the agents and the pending questions every time it is asked
/// for, and a second copy of it on disk would be the one thing 021's FR-001 forbids. What
/// is here is only: this was raised then, and that has been shown there.
public struct AttentionRecords: Codable, Hashable, Sendable {
    public var raised: [RaisedNote]
    public var deliveries: [Delivery]
    public var withdrawing: [PendingWithdrawal]

    /// How long a withdrawal keeps trying. A retry, not a queue: seven days matches the
    /// spend ledger's horizon and exists so this cannot grow without end.
    public static let withdrawalHorizon: TimeInterval = 7 * 24 * 60 * 60

    public init(raised: [RaisedNote] = [], deliveries: [Delivery] = [],
                withdrawing: [PendingWithdrawal] = []) {
        self.raised = raised
        self.deliveries = deliveries
        self.withdrawing = withdrawing
    }

    /// One bad entry costs that entry, not the file — the rule `Lossy` already gives the
    /// project list. A note is bookkeeping; losing all of it to one malformed line would
    /// be a repeated notification for every outstanding need, to save nothing.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        raised = (try c.decodeIfPresent([Lossy<RaisedNote>].self, forKey: .raised) ?? [])
            .compactMap(\.value)
        deliveries = (try c.decodeIfPresent([Lossy<Delivery>].self, forKey: .deliveries) ?? [])
            .compactMap(\.value)
        withdrawing = (try c.decodeIfPresent([Lossy<PendingWithdrawal>].self, forKey: .withdrawing) ?? [])
            .compactMap(\.value)
    }

    enum CodingKeys: String, CodingKey {
        case raised, deliveries, withdrawing
    }

    /// What may actually be acted on, given the devices this daemon knows and the time.
    ///
    /// Pure, and separate from reading the file, so both rules can be exercised without a
    /// daemon: nothing is shown on, or withdrawn from, a device that is not on record
    /// (FR-006), and a withdrawal stops trying after a week.
    ///
    /// A `raised` note is **not** dropped with a device. When a need was first raised is
    /// a fact about the need, not about where it happened to be shown.
    public func pruned(knownDevices: Set<UUID>, now: Date) -> AttentionRecords {
        AttentionRecords(
            raised: raised,
            deliveries: deliveries.filter { delivery in
                // A delivery to the Mac, or to nowhere, names no device and survives
                // whatever the device list says.
                guard let device = delivery.to?.deviceID else { return true }
                return knownDevices.contains(device)
            },
            withdrawing: withdrawing.filter { withdrawal in
                knownDevices.contains(withdrawal.device)
                    && now.timeIntervalSince(withdrawal.decidedAt) < Self.withdrawalHorizon
            })
    }
}

/// Where those notes are kept: `attention.json` under the daemon's root, beside
/// `projects.json`, `workflows.json` and `devices.json`, read whole and written whole.
///
/// **The daemon is the only writer.** Deliberately dumb — every rule about what may be
/// *acted* on lives in `AttentionRecords.pruned(knownDevices:now:)`, which is pure.
///
/// A missing or unreadable file is no notes at all, and the daemon starts anyway. What
/// that costs is what every daemon before this file cost: an outstanding need is raised
/// afresh, and the person may be told about it a second time. That is the failure this
/// exists to make rare, and it is never made worse by losing it.
public struct AttentionStore: Sendable {
    private let locations: StoreLocations

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    public func load() -> AttentionRecords {
        guard let data = try? Data(contentsOf: locations.attention),
              let records = try? StoreCoding.decoder.decode(AttentionRecords.self, from: data) else {
            return AttentionRecords()
        }
        return records
    }

    /// Never throws. A note that cannot be written is a notification that may repeat,
    /// which is not worth taking the daemon down for — the same position `WorkflowStore`
    /// takes about a pause it could not save.
    public func save(_ records: AttentionRecords) {
        guard let data = try? StoreCoding.encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try? data.write(to: locations.attention, options: .atomic)
    }
}
