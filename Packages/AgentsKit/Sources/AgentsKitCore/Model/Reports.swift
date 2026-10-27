import Foundation

/// Reports (#1811): usage, cost and time by person, folder, machine and runtime, added up
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
        /// Me, a group or the organisation (#1804); with none, an admin's is every person.
        public var scope: ReportScope?

        public init(range: ReportRange, format: ReportFormat? = nil, scope: ReportScope? = nil) {
            self.range = range
            self.format = format
            self.scope = scope
        }
    }

    /// Me, a group's people, or every person (#1804).
    enum ReportScopeKind: String, Codable, Sendable, Hashable, CaseIterable {
        case me, group, org
    }

    /// Whose rows a report adds up (#1804).
    struct ReportScope: Codable, Sendable, Hashable {
        public var kind: ReportScopeKind
        /// The group's id, for `group`.
        public var group: String?

        public init(kind: ReportScopeKind, group: String? = nil) {
            self.kind = kind
            self.group = group
        }
    }

    /// A scope the caller may see, with its name (#1804).
    struct ReportScopeOption: Codable, Sendable, Hashable {
        public var scope: ReportScope
        public var name: String

        public init(scope: ReportScope, name: String) {
            self.scope = scope
            self.name = name
        }
    }

    /// `reports/scopes`' answer (#1804): Me, the groups the caller leads (every group for an
    /// admin), and the organisation for an admin.
    struct ReportScopes: Codable, Sendable, Hashable {
        public var scopes: [ReportScopeOption]
        public var admin: Bool

        public init(scopes: [ReportScopeOption], admin: Bool) {
            self.scopes = scopes
            self.admin = admin
        }
    }

    /// Who sees what in Reports (#1804), an admin's to set in Console ▸ Report Policy.
    struct ReportPolicy: Codable, Sendable, Hashable {
        /// A group lead sees the group's totals only, with no person or machine named.
        public var totalsOnly: Bool
        /// Each group's leads, by group id.
        public var leads: [String: [String]]
        /// A budget for a calendar month in US dollars, by group id, or "org".
        public var budgetsUSD: [String: Double]

        public init(totalsOnly: Bool = false, leads: [String: [String]] = [:], budgetsUSD: [String: Double] = [:]) {
            self.totalsOnly = totalsOnly
            self.leads = leads
            self.budgetsUSD = budgetsUSD
        }
    }

    /// One hour or day of one machine's folder and runtime, with its person.
    struct ReportRow: Codable, Sendable, Hashable {
        /// The UTC hour ("2026-10-21T15") or day ("2026-10-21").
        public var at: String
        public var person: String
        public var personName: String
        public var host: String
        public var hostName: String
        public var folder: String
        /// The project the folder is in (#2670), by id, as its machine last reported it; nil
        /// for a folder in no project.
        public var project: String?
        /// The project's name, nil with project.
        public var projectName: String?
        public var runtime: String
        /// The workflow that started the agents of this row (#2019), by its id; nil for agents
        /// a person or another agent started.
        public var workflow: String?
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
        /// The person's groups, by id, for a group or organisation scope (#1804).
        public var groups: [String]?
        /// What the agents did (#2019): sessions, pull requests and waits. Nil from a machine
        /// before #2019, whose rows count as nothing done.
        public var counts: ReportCounts?

        public init(at: String, person: String, personName: String, host: String, hostName: String,
                    folder: String, project: String? = nil, projectName: String? = nil, runtime: String,
                    workflow: String? = nil, cost: [String: Decimal] = [:],
                    inputTokens: Int = 0, outputTokens: Int = 0, thoughtTokens: Int = 0, cachedReadTokens: Int = 0,
                    cachedWriteTokens: Int = 0, turns: Int = 0, unpricedTurns: Int = 0,
                    workingSeconds: Double = 0, waitingSeconds: Double = 0, groups: [String]? = nil,
                    counts: ReportCounts? = nil) {
            self.at = at
            self.person = person
            self.personName = personName
            self.host = host
            self.hostName = hostName
            self.folder = folder
            self.project = project
            self.projectName = projectName
            self.runtime = runtime
            self.workflow = workflow
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
            self.groups = groups
            self.counts = counts
        }
    }

    /// What the agents of a report row did (#2019), counted on the machine.
    struct ReportCounts: Codable, Sendable, Hashable {
        /// Agents that began their first turn (agent.started).
        public var sessions: Int
        /// Agents that ended in an error that nobody chose (agent.failed).
        public var failedSessions: Int
        /// Pull and merge requests opened from an agent's branch on this machine (pr.opened).
        public var prsOpened: Int
        /// Those merged (pr.merged).
        public var prsMerged: Int
        /// Of those merged, the ones whose title starts with "Revert".
        public var prsReverted: Int
        /// The merged ones' time from their agent's start to the merge, added up.
        public var mergeSeconds: Double
        /// The times an agent waited for its person in a turn.
        public var waits: Int
        /// The waits by length: under 1 minute, 5, 15, 60, 240, and longer.
        public var waitBuckets: [Int]
        /// Runs a workflow started (workflow.ran).
        public var workflowRuns: Int
        /// Runs whose agent ended in an error.
        public var workflowFailures: Int

        public init(sessions: Int = 0, failedSessions: Int = 0, prsOpened: Int = 0, prsMerged: Int = 0,
                    prsReverted: Int = 0, mergeSeconds: Double = 0, waits: Int = 0,
                    waitBuckets: [Int] = [0, 0, 0, 0, 0, 0], workflowRuns: Int = 0, workflowFailures: Int = 0) {
            self.sessions = sessions
            self.failedSessions = failedSessions
            self.prsOpened = prsOpened
            self.prsMerged = prsMerged
            self.prsReverted = prsReverted
            self.mergeSeconds = mergeSeconds
            self.waits = waits
            self.waitBuckets = waitBuckets
            self.workflowRuns = workflowRuns
            self.workflowFailures = workflowFailures
        }
    }

    /// `reports/usage`'s answer: rows oldest first, by the hour for D and by the day otherwise.
    struct UsageReport: Codable, Sendable, Hashable {
        public var range: ReportRange
        public var rows: [ReportRow]
        /// Whether the caller sees every person's machines.
        public var admin: Bool
        /// The scope the rows are of (#1804).
        public var scope: ReportScope?
        /// The rows name no person and no machine: a group lead's view under totals only.
        public var personsHidden: Bool?
        /// The name of each group the rows name.
        public var groupNames: [String: String]?
        /// The scope's budget for a calendar month, in US dollars.
        public var budgetUSD: Double?
        /// What the scope spent this calendar month (UTC), in US dollars, beside the budget.
        public var monthSpentUSD: Double?

        public init(range: ReportRange, rows: [ReportRow], admin: Bool, scope: ReportScope? = nil,
                    personsHidden: Bool? = nil, groupNames: [String: String]? = nil, budgetUSD: Double? = nil,
                    monthSpentUSD: Double? = nil) {
            self.range = range
            self.rows = rows
            self.admin = admin
            self.scope = scope
            self.personsHidden = personsHidden
            self.groupNames = groupNames
            self.budgetUSD = budgetUSD
            self.monthSpentUSD = monthSpentUSD
        }
    }

    /// A page of Reports (#1804, #2019).
    enum ReportPage: String, Codable, Sendable, Hashable, CaseIterable {
        case spend, outcomes, time, runtimes, adoption, workflows
    }

    /// A saved view of Reports (#2019, R8): a page with its scope, range and way to add up,
    /// kept for the person who saved it. The web page saves and opens them.
    struct ReportView: Codable, Sendable, Hashable {
        /// Given by the control plane; empty to save a new view.
        public var id: String
        public var name: String
        public var page: ReportPage
        public var scope: ReportScope
        public var range: ReportRange
        /// person, folder, machine, runtime, group or workflow.
        public var by: String?

        public init(id: String = "", name: String, page: ReportPage, scope: ReportScope, range: ReportRange, by: String? = nil) {
            self.id = id
            self.name = name
            self.page = page
            self.scope = scope
            self.range = range
            self.by = by
        }
    }

    /// `reports/deleteView`'s params (#2019).
    struct ReportViewID: Codable, Sendable, Hashable {
        public var id: String

        public init(id: String) { self.id = id }
    }

    /// The caller's saved views of Reports (#2019), in the order they were saved.
    struct ReportViews: Codable, Sendable, Hashable {
        public var views: [ReportView]

        public init(views: [ReportView] = []) { self.views = views }
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
    /// `Empty` → `ReportScopes` (#1804).
    static let reportsScopes = "reports/scopes"
    /// `Empty` → `ReportPolicy` (#1804). Admins only.
    static let reportsPolicy = "reports/policy"
    /// `ReportPolicy` → `ReportPolicy` (#1804). Admins only.
    static let reportsSetPolicy = "reports/setPolicy"
    /// `Empty` → `ReportViews` (#2019).
    static let reportsViews = "reports/views"
    /// `ReportView` → `ReportViews` (#2019).
    static let reportsSaveView = "reports/saveView"
    /// `ReportViewID` → `ReportViews` (#2019).
    static let reportsDeleteView = "reports/deleteView"
}
