import Foundation
import AgentsKitCore

/// What the work used over time, by runtime (#823): the history behind the usage
/// charts. `UsageHistory` says what is kept and why it stays bounded.
///
/// Held in memory once read, as `SpendLedger` is: `record` changes memory, `flush`
/// writes. The daemon is the only writer of this file while it runs.
///
/// The first run with no file is seeded once, in the background, from what is still on
/// disk: the days `spend.json` holds (cost, with no runtime) and the usage reports in
/// the transcripts not yet deleted (tokens, by runtime). Only what happened before this
/// ledger was made is seeded, so a turn the daemon records itself is never counted twice.
public final class UsageLedger: @unchecked Sendable {
    private let locations: StoreLocations
    private let calendar: Calendar
    private let lock = NSLock()
    private var held: UsageHistory?
    private var unwritten = false
    /// When this ledger was made: the seed takes only what came before.
    private let madeAt: Date
    /// `spend.json` as it was when this ledger was made, for the seed.
    private let spendBefore: [String: [String: Decimal]]
    private let needsSeed: Bool

    public init(locations: StoreLocations, now: Date = Date(), calendar: Calendar = .current) {
        self.locations = locations
        self.calendar = calendar
        self.madeAt = now
        self.needsSeed = !FileManager.default.fileExists(atPath: locations.usageHistory.path)
        self.spendBefore = needsSeed ? Self.spendDays(at: locations.spend) : [:]
    }

    /// Bank one cost, as it is banked into the day's spend.
    public func record(_ cost: Cost, runtime: String, on date: Date) {
        record(UsageBucket(cost: cost), runtime: runtime, on: date)
    }

    /// Bank one finished turn's tokens.
    public func record(_ usage: TurnUsage, priced: Bool, runtime: String, on date: Date) {
        record(UsageBucket(turn: usage, priced: priced), runtime: runtime, on: date)
    }

    private func record(_ bucket: UsageBucket, runtime: String, on date: Date) {
        lock.withLock {
            var history = readLocked()
            history.add(bucket, runtime: runtime, hour: UsageHistory.hourStamp(for: date, calendar: calendar))
            held = history
            unwritten = true
        }
    }

    /// Write what `record` added, if anything. A failed write stays unwritten.
    public func flush() throws {
        try lock.withLock {
            guard unwritten, var history = held else { return }
            history.prune()
            held = history
            try StoreFile.write(try StoreCoding.encoder.encode(history), to: locations.usageHistory)
            unwritten = false
        }
    }

    /// What is kept, stamped with the host's hour now.
    public func history(at now: Date) -> UsageHistory {
        lock.withLock {
            var history = readLocked()
            history.prune()
            history.now = UsageHistory.hourStamp(for: now, calendar: calendar)
            history.timeZone = calendar.timeZone.identifier
            return history
        }
    }

    /// Seed a first run from what is on disk, then write. Called once, off the daemon's
    /// actor: the transcripts can be hundreds of megabytes. Does nothing when the file
    /// was already there.
    public func seedIfNeeded() {
        guard needsSeed else { return }
        let seed = Self.seed(spend: spendBefore, agents: locations.agents, before: madeAt, calendar: calendar)
        lock.withLock {
            var history = readLocked()
            for (hour, runtimes) in seed.hours {
                for (runtime, bucket) in runtimes {
                    history.hours[hour, default: [:]][runtime, default: UsageBucket()].add(bucket)
                }
            }
            for (day, runtimes) in seed.days {
                for (runtime, bucket) in runtimes {
                    history.days[day, default: [:]][runtime, default: UsageBucket()].add(bucket)
                }
            }
            held = history
            unwritten = true
        }
        try? flush()
    }

    private func readLocked() -> UsageHistory {
        if let held { return held }
        let read = StoreFile.load(UsageHistory.self, at: locations.usageHistory, empty: UsageHistory(),
                                  meaning: "the usage charts start again from nothing")
        held = read
        return read
    }

    // MARK: Seed

    private struct SpendFile: Decodable { var days: [String: [String: Decimal]] }
    private struct AgentRuntime: Decodable { var runtimeID: String }
    private struct UsageLine: Decodable {
        struct Kind: Decodable {
            struct Wrapped: Decodable { var _0: TurnUsage }
            var usageRecorded: Wrapped
        }
        var at: Date
        var kind: Kind
    }

    static func spendDays(at url: URL) -> [String: [String: Decimal]] {
        guard let data = try? Data(contentsOf: url),
              let file = try? StoreCoding.decoder.decode(SpendFile.self, from: data) else { return [:] }
        return file.days
    }

    /// Cost by day from the spend ledger, unattributed; tokens by hour and runtime from
    /// every transcript still on disk, before `cutoff`.
    static func seed(spend: [String: [String: Decimal]], agents: URL, before cutoff: Date,
                     calendar: Calendar) -> UsageHistory {
        var history = UsageHistory()
        for (day, costs) in spend where !costs.isEmpty {
            history.days[day, default: [:]][UsageHistory.unattributed] = UsageBucket(cost: costs)
        }
        let oldest = calendar.date(byAdding: .day, value: -UsageHistory.daysKept, to: cutoff) ?? .distantPast
        let marker = Data("usageRecorded".utf8)
        let folders = (try? FileManager.default.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let record = try? Data(contentsOf: folder.appendingPathComponent("agent.json")),
                  let runtime = try? StoreCoding.decoder.decode(AgentRuntime.self, from: record).runtimeID,
                  let transcript = try? Data(contentsOf: folder.appendingPathComponent("transcript.jsonl"),
                                             options: .mappedIfSafe) else { continue }
            for line in transcript.split(separator: UInt8(ascii: "\n")) where line.range(of: marker) != nil {
                guard let entry = try? StoreCoding.decoder.decode(UsageLine.self, from: Data(line)),
                      entry.at < cutoff, entry.at >= oldest else { continue }
                // A seeded turn says nothing about price: the cost came from spend.json.
                let bucket = UsageBucket(turn: entry.kind.usageRecorded._0, priced: true)
                let hour = UsageHistory.hourStamp(for: entry.at, calendar: calendar)
                if let hourDate = UsageChart.date(hour, calendar: calendar),
                   cutoff.timeIntervalSince(hourDate) < Double(UsageHistory.hoursKept) * 3600 {
                    history.hours[hour, default: [:]][runtime, default: UsageBucket()].add(bucket)
                }
                history.days[String(hour.prefix(10)), default: [:]][runtime, default: UsageBucket()].add(bucket)
            }
        }
        history.prune()
        return history
    }
}
