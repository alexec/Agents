import Foundation

/// Reports (#1811): usage, cost and time by person, project, machine and runtime, added up
/// on the control plane from what each machine sends it each hour. Hours and days are UTC,
/// so machines in other time zones add up into the same ones.
public extension DaemonAPI {
    /// D is the last 24 hours by the hour; W, M and 3M the last 7, 30 and 90 days by the day.
    enum ReportRange: String, Codable, Sendable, Hashable, CaseIterable {
        case day, week, month, threeMonths
    }

    enum ReportFormat: String, Codable, Sendable, Hashable, CaseIterable {
        case csv, jsonl
    }

    /// `reports/usage` and `reports/export`. An admin sees every person; a member their own
    /// machines.
    struct ReportQuery: Codable, Sendable, Hashable {
        public var range: ReportRange
        /// For `reports/export`; CSV when absent.
        public var format: ReportFormat?

        public init(range: ReportRange, format: ReportFormat? = nil) {
            self.range = range
            self.format = format
        }
    }

    /// One hour or day of one machine's project and runtime, with its person.
    struct ReportRow: Codable, Sendable, Hashable {
        /// The UTC hour ("2026-10-21T15") or day ("2026-10-21").
        public var at: String
        public var person: String
        public var personName: String
        public var host: String
        public var hostName: String
        public var project: String
        public var runtime: String
        /// Per currency, never added across.
        public var cost: [String: Decimal]
        public var inputTokens: Int
        public var outputTokens: Int
        public var thoughtTokens: Int
        public var cachedReadTokens: Int
        public var cachedWriteTokens: Int
        public var turns: Int
        public var unpricedTurns: Int
        /// The agent, its tools and waiting on others.
        public var workingSeconds: Double
        /// Waiting for the person.
        public var waitingSeconds: Double

        public init(at: String, person: String, personName: String, host: String, hostName: String,
                    project: String, runtime: String, cost: [String: Decimal] = [:], inputTokens: Int = 0,
                    outputTokens: Int = 0, thoughtTokens: Int = 0, cachedReadTokens: Int = 0,
                    cachedWriteTokens: Int = 0, turns: Int = 0, unpricedTurns: Int = 0,
                    workingSeconds: Double = 0, waitingSeconds: Double = 0) {
            self.at = at
            self.person = person
            self.personName = personName
            self.host = host
            self.hostName = hostName
            self.project = project
            self.runtime = runtime
            self.cost = cost
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.thoughtTokens = thoughtTokens
            self.cachedReadTokens = cachedReadTokens
            self.cachedWriteTokens = cachedWriteTokens
            self.turns = turns
            self.unpricedTurns = unpricedTurns
            self.workingSeconds = workingSeconds
            self.waitingSeconds = waitingSeconds
        }
    }

    /// `reports/usage`'s answer: rows oldest first, by the hour for D and by the day otherwise.
    struct UsageReport: Codable, Sendable, Hashable {
        public var range: ReportRange
        public var rows: [ReportRow]
        /// Whether the caller sees every person's machines.
        public var admin: Bool

        public init(range: ReportRange, rows: [ReportRow], admin: Bool) {
            self.range = range
            self.rows = rows
            self.admin = admin
        }
    }

    /// `reports/export`'s answer: the rows as CSV or JSON lines.
    struct ReportExport: Codable, Sendable, Hashable {
        public var text: String
        public var count: Int
        public var format: ReportFormat
    }
}

public extension DaemonAPI.Method {
    /// `ReportQuery` → `UsageReport` (#1811).
    static let reportsUsage = "reports/usage"
    /// `ReportQuery` → `ReportExport` (#1811).
    static let reportsExport = "reports/export"
}
