import Foundation
import AgentsKitCore

/// What each of the last few local days cost, per currency.
///
/// This exists for one reason: the day's total has to survive a restart. An agent's
/// own total already does, but agents are archived and ended and the day's figure has
/// to count those too, so it cannot be derived by adding up the agents that happen to
/// still be about.
///
/// It is **not** a history and must never be shown as one. Days beyond today are kept
/// only so that every boundary question — a spend banked either side of midnight, a
/// daemon restarted at four in the morning — has an unambiguous answer.
public struct SpendLedger: Sendable {
    private let locations: StoreLocations

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    /// How many days are kept. Seven makes every boundary question unambiguous. It is
    /// not an offer of history and must not be surfaced anywhere.
    public static let daysKept = 7

    /// The shape on disk: `{"days": {"2026-09-19": {"USD": 12.34}}}`.
    struct Contents: Codable, Sendable {
        var days: [String: [String: Decimal]]
        init(days: [String: [String: Decimal]] = [:]) { self.days = days }
    }

    /// The machine's own local calendar day. Taken at the moment of banking, and the
    /// day a spend belongs to is the day its turn ended — nothing is ever
    /// re-attributed later.
    ///
    /// `Calendar.current` rather than a fixed zone, so the day follows the machine
    /// when the clock changes or it travels. A day that is short or long because the
    /// clock moved is still one day.
    public static func stamp(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Add a turn's cost into its day's bucket and write.
    ///
    /// Called once per turn from `finishTurn`, before the agent is broadcast, so a
    /// daemon killed between the two comes back having counted the money.
    public func add(_ cost: Cost, on date: Date) {
        var contents = read()
        let day = Self.stamp(for: date)
        contents.days[day, default: [:]][cost.currency, default: 0] += cost.amount
        write(contents, keeping: day)
    }

    /// What was spent on that local day, per currency. Empty when nothing was, so a
    /// view shows nothing rather than a zero.
    public func total(on date: Date) -> [String: Decimal] {
        read().days[Self.stamp(for: date)] ?? [:]
    }

    /// A missing or unreadable file is an empty ledger. A daemon that cannot read its
    /// own ledger must not refuse to work; it under-counts today and says so by
    /// showing what it has.
    private func read() -> Contents {
        guard let data = try? Data(contentsOf: locations.spend),
              let contents = try? StoreCoding.decoder.decode(Contents.self, from: data) else {
            return Contents()
        }
        return contents
    }

    /// Pruned on write, relative to the day being written rather than to the clock,
    /// so banking a late figure does not drop the day it belongs to.
    private func write(_ contents: Contents, keeping day: String) {
        var contents = contents
        let keep = contents.days.keys.sorted().suffix(Self.daysKept)
        contents.days = contents.days.filter { keep.contains($0.key) || $0.key == day }
        guard let data = try? StoreCoding.encoder.encode(contents) else { return }
        try? FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try? data.write(to: locations.spend, options: .atomic)
    }
}
