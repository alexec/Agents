import Foundation

/// The bars of a usage chart (#823), worked out once here for the window and the
/// Remote; the page has `usageChart` in usage.ts, which follows this.
///
/// As Health has it: D is today by the hour, W the last seven days, M the last thirty,
/// and 3M the last thirteen weeks by the week. Every stamp is the host's, counted back
/// from `UsageHistory.now`; nothing asks the reader's clock.
public struct UsageChart: Sendable, Hashable {
    public enum Range: String, CaseIterable, Sendable, Hashable, Identifiable {
        case day = "D", week = "W", month = "M", threeMonths = "3M"
        public var id: String { rawValue }
    }

    public enum Metric: String, CaseIterable, Sendable, Hashable, Identifiable {
        case cost = "Cost", tokens = "Tokens"
        public var id: String { rawValue }
    }

    public struct Bar: Sendable, Hashable, Identifiable {
        /// The first stamp the bar covers: an hour, a day, or a week's first day.
        public let stamp: String
        public let start: Date
        public let value: Double
        public var id: String { stamp }
    }

    public struct Share: Sendable, Hashable, Identifiable {
        public let runtime: String
        public let value: Double
        public var id: String { runtime }
    }

    public let range: Range
    public let metric: Metric
    /// The currency the cost is drawn in: the one most was spent in. Nil for tokens,
    /// or when nothing was priced.
    public let currency: String?
    public let bars: [Bar]
    /// The whole range, by runtime, largest first.
    public let shares: [Share]
    public let total: Double
    /// Per day, over the days that have any data, as Health's average does. For D, the
    /// day's total.
    public let average: Double
    /// Cache reads in the range, said beside the token bars rather than drawn in them.
    public let cachedReadTokens: Int
    /// Turns in the range a runtime would not price: the cost drawn is a floor.
    public let unpricedTurns: Int
    /// Currencies other than `currency` that something in the range was spent in.
    public let otherCurrencies: [String]

    public init(_ history: UsageHistory, range: Range, metric: Metric, calendar: Calendar = .current) {
        self.range = range
        self.metric = metric
        let now = Self.date(history.now, calendar: calendar) ?? Date()
        let today = calendar.startOfDay(for: now)

        // The slots, oldest first, each the stamps it adds up.
        var slots: [(stamp: String, start: Date, keys: [String])] = []
        let tier: [String: [String: UsageBucket]]
        switch range {
        case .day:
            tier = history.hours
            for hour in 0..<24 {
                let start = calendar.date(byAdding: .hour, value: hour, to: today)!
                let stamp = UsageHistory.hourStamp(for: start, calendar: calendar)
                slots.append((stamp, start, [stamp]))
            }
        case .week, .month:
            tier = history.days
            let count = range == .week ? 7 : 30
            for back in stride(from: count - 1, through: 0, by: -1) {
                let start = calendar.date(byAdding: .day, value: -back, to: today)!
                let stamp = Self.dayStamp(start, calendar: calendar)
                slots.append((stamp, start, [stamp]))
            }
        case .threeMonths:
            tier = history.days
            for week in stride(from: 12, through: 0, by: -1) {
                let start = calendar.date(byAdding: .day, value: -(week * 7 + 6), to: today)!
                let keys = (0..<7).map {
                    Self.dayStamp(calendar.date(byAdding: .day, value: $0, to: start)!, calendar: calendar)
                }
                slots.append((keys[0], start, keys))
            }
        }

        var merged = UsageBucket()
        var byRuntime: [String: UsageBucket] = [:]
        var daysWithData = Set<String>()
        for slot in slots {
            for key in slot.keys {
                guard let runtimes = tier[key] else { continue }
                for (runtime, bucket) in runtimes {
                    merged.add(bucket)
                    byRuntime[runtime, default: UsageBucket()].add(bucket)
                }
                daysWithData.insert(String(key.prefix(10)))
            }
        }
        let currencies = merged.cost.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let currency = metric == .cost ? currencies.first?.key : nil
        self.currency = currency
        self.otherCurrencies = metric == .cost ? currencies.dropFirst().map(\.key).sorted() : []

        func value(_ bucket: UsageBucket) -> Double {
            switch metric {
            case .cost: currency.flatMap { bucket.cost[$0] }.map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
            case .tokens: Double(bucket.freshTokens)
            }
        }
        self.bars = slots.map { slot in
            var bucket = UsageBucket()
            for key in slot.keys { tier[key]?.values.forEach { bucket.add($0) } }
            return Bar(stamp: slot.stamp, start: slot.start, value: value(bucket))
        }
        self.shares = byRuntime.map { Share(runtime: $0.key, value: value($0.value)) }
            .filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.runtime < $1.runtime }
        self.total = value(merged)
        self.average = range == .day ? total : total / Double(max(1, daysWithData.count))
        self.cachedReadTokens = merged.cachedReadTokens
        self.unpricedTurns = merged.unpricedTurns
    }

    /// Nothing at all in the range: the page says so rather than drawing flat bars.
    public var isEmpty: Bool { total == 0 }

    /// The figure above the bars, as Health words it.
    public var headline: String { range == .day ? "Total" : "Daily average" }

    /// A figure of this metric, for the eye.
    public func words(_ value: Double) -> String {
        switch metric {
        case .cost:
            return Decimal(value).money(in: currency ?? "USD")
        case .tokens:
            return Self.tokenWords(value)
        }
    }

    /// 1.2K, 34M, 5.6B: a token count read at a glance.
    public static func tokenWords(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    /// What a runtime id is called on the chart.
    public static func runtimeName(_ id: String) -> String {
        id == UsageHistory.unattributed ? "Earlier" : (RuntimeCatalog.runtime(id: id)?.name ?? id)
    }

    public static func dayStamp(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// A stamp read back in the given calendar. `yyyy-MM-ddTHH` or `yyyy-MM-dd`.
    public static func date(_ stamp: String, calendar: Calendar = .current) -> Date? {
        let numbers = stamp.split(whereSeparator: { $0 == "-" || $0 == "T" }).compactMap { Int($0) }
        guard numbers.count >= 3 else { return nil }
        return calendar.date(from: DateComponents(year: numbers[0], month: numbers[1], day: numbers[2],
                                                  hour: numbers.count > 3 ? numbers[3] : 0))
    }
}
