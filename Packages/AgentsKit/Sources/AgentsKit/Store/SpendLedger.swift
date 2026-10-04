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
///
/// Held in memory once read (#177): a busy turn quotes its cost on several usage
/// updates, and each used to read the file, rewrite it, and read it twice more for the
/// limits. Now `record` changes memory, `flush` writes, and `add` does both. The daemon
/// is the only writer of this file while it runs.
public final class SpendLedger: @unchecked Sendable {
    private let locations: StoreLocations
    private let lock = NSLock()
    /// The file's contents, once read.
    private var held: Contents?
    /// The day of the last change not yet written, or nil when the file is current.
    private var unwritten: String?

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
    public func add(_ cost: Cost, on date: Date) throws {
        record(cost, on: date)
        try flush()
    }

    /// Add a cost into its day's bucket in memory only; `flush` writes it.
    public func record(_ cost: Cost, on date: Date) {
        lock.withLock {
            var contents = readLocked()
            let day = Self.stamp(for: date)
            contents.days[day, default: [:]][cost.currency, default: 0] += cost.amount
            held = contents
            unwritten = day
        }
    }

    /// Write what `record` added, if anything. A failed write stays unwritten, for the
    /// next flush to try again.
    public func flush() throws {
        try lock.withLock {
            guard let day = unwritten, let contents = held else { return }
            try write(contents, keeping: day)
            unwritten = nil
        }
    }

    /// Whether `record` added anything not yet written.
    public var hasUnwritten: Bool { lock.withLock { unwritten != nil } }

    /// What was spent on that local day, per currency. Empty when nothing was, so a
    /// view shows nothing rather than a zero.
    public func total(on date: Date) -> [String: Decimal] {
        lock.withLock { readLocked().days[Self.stamp(for: date)] ?? [:] }
    }

    /// A missing file is an empty ledger. An unreadable one is set aside and is empty
    /// too (#171): a daemon that cannot read its own ledger must not refuse to work; it
    /// under-counts today, and the limits say so (`note`). Read once, then held.
    private func readLocked() -> Contents {
        if let held { return held }
        let read = StoreFile.load(Contents.self, at: locations.spend, empty: Contents(),
                                  meaning: "today's spend starts again from nothing")
        held = read
        return read
    }

    /// What the limits say while this run set the ledger aside, or nil.
    public var note: String? {
        SetAsideNotes.shared.note(for: locations.spend)
            .map { "\($0) Today's spend may be under-counted." }
    }

    /// Pruned on write, relative to the day being written rather than to the clock,
    /// so banking a late figure does not drop the day it belongs to.
    private func write(_ contents: Contents, keeping day: String) throws {
        var contents = contents
        let keep = contents.days.keys.sorted().suffix(Self.daysKept)
        contents.days = contents.days.filter { keep.contains($0.key) || $0.key == day }
        held = contents
        try StoreFile.write(try StoreCoding.encoder.encode(contents), to: locations.spend)
    }
}
