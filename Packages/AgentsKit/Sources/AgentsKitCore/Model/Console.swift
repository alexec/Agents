import Foundation

/// The Console (#1804): the control plane's app for its admins, on the web page. The window
/// and the Remote do not draw it; these types are here so `WebSignatures` names them.
public extension DaemonAPI {
    /// One machine on Console ▸ Machines: its `machines/list` row, whose it is, and how many of
    /// its agents were running when it last listed them. Numbers only.
    struct FleetMachine: Codable, Sendable, Hashable {
        public var host: ControlMachine
        /// Its person's or bot's name; empty when nobody owns it.
        public var ownerName: String
        public var bot: Bool
        public var running: Int?
        public var heardAt: Date?

        public init(host: ControlMachine, ownerName: String, bot: Bool, running: Int? = nil, heardAt: Date? = nil) {
            self.host = host
            self.ownerName = ownerName
            self.bot = bot
            self.running = running
            self.heardAt = heardAt
        }
    }

    /// `console/fleet`'s answer: every machine on the control plane, for an admin.
    struct FleetBoard: Codable, Sendable, Hashable {
        public var machines: [FleetMachine]

        public init(machines: [FleetMachine]) {
            self.machines = machines
        }
    }
}

public extension DaemonAPI {
    /// One workflow a bot ran in the last 7 days (M6): how many times, and when last.
    struct TeamWorkflowRuns: Codable, Sendable, Hashable {
        public var workflow: String
        public var runs: Int
        public var lastRunAt: Date?

        public init(workflow: String, runs: Int, lastRunAt: Date? = nil) {
            self.workflow = workflow
            self.runs = runs
            self.lastRunAt = lastRunAt
        }
    }

    /// An agent running on a bot's machine, by id, for `bots/stopRun`. No title.
    struct TeamBotRun: Codable, Sendable, Hashable {
        public var host: String
        public var hostName: String
        public var agent: UUID
        public var workflow: String?
        public var since: Date?

        public init(host: String, hostName: String, agent: UUID, workflow: String? = nil, since: Date? = nil) {
            self.host = host
            self.hostName = hostName
            self.agent = agent
            self.workflow = workflow
            self.since = since
        }
    }

    /// One agent on Console ▸ Live Now (#2019, M9): whose machine, which runtime, its state,
    /// since when and its cost so far. No title and nothing it said.
    struct LiveAgent: Codable, Sendable, Hashable {
        public var host: String
        public var hostName: String
        public var owner: String
        public var ownerName: String
        public var bot: Bool
        public var agent: UUID
        public var runtime: String
        public var state: AgentState
        /// It waits for an event or another agent, not for its person.
        public var waitsOnOthers: Bool?
        public var workflow: String?
        public var since: Date?
        /// Its cost so far, by currency.
        public var costToDate: [String: Double]?
        /// When the machine last listed its agents.
        public var heardAt: Date?

        public init(host: String, hostName: String, owner: String, ownerName: String, bot: Bool, agent: UUID,
                    runtime: String, state: AgentState, waitsOnOthers: Bool? = nil, workflow: String? = nil,
                    since: Date? = nil, costToDate: [String: Double]? = nil, heardAt: Date? = nil) {
            self.host = host
            self.hostName = hostName
            self.owner = owner
            self.ownerName = ownerName
            self.bot = bot
            self.agent = agent
            self.runtime = runtime
            self.state = state
            self.waitsOnOthers = waitsOnOthers
            self.workflow = workflow
            self.since = since
            self.costToDate = costToDate
            self.heardAt = heardAt
        }
    }

    /// `console/live`'s answer (#2019, M9): every agent running now, the most costly first.
    struct LiveBoard: Codable, Sendable, Hashable {
        public var agents: [LiveAgent]

        public init(agents: [LiveAgent]) {
            self.agents = agents
        }
    }

    /// `console/stopAgent` (#2019, M9): an admin stops one agent on any machine.
    struct ConsoleStopAgent: Codable, Sendable, Hashable {
        public var host: MachineRef
        public var agent: UUID

        public init(host: MachineRef, agent: UUID) {
            self.host = host
            self.agent = agent
        }
    }

    /// A bot on Console ▸ Team Workflows (M6).
    struct TeamBot: Codable, Sendable, Hashable {
        public var user: String
        public var name: String
        public var group: String?
        public var groupName: String?
        public var caps: SpendCaps?
        public var spentTodayUSD: Double
        /// At its own or its group's cap until midnight UTC.
        public var capped: Bool
        public var machines: Int
        public var online: Int
        public var workflows: [TeamWorkflowRuns]
        public var live: [TeamBotRun]

        public init(user: String, name: String, group: String? = nil, groupName: String? = nil, caps: SpendCaps? = nil,
                    spentTodayUSD: Double = 0, capped: Bool = false, machines: Int = 0, online: Int = 0,
                    workflows: [TeamWorkflowRuns] = [], live: [TeamBotRun] = []) {
            self.user = user
            self.name = name
            self.group = group
            self.groupName = groupName
            self.caps = caps
            self.spentTodayUSD = spentTodayUSD
            self.capped = capped
            self.machines = machines
            self.online = online
            self.workflows = workflows
            self.live = live
        }
    }

    /// `console/teamWorkflows`' answer: every bot, for an admin.
    struct TeamWorkflows: Codable, Sendable, Hashable {
        public var bots: [TeamBot]

        public init(bots: [TeamBot]) {
            self.bots = bots
        }
    }
}

public extension DaemonAPI.Method {
    /// `Empty` → `FleetBoard` (#1804, M1). Admins only.
    static let consoleFleet = "console/fleet"
    /// `Empty` → `TeamWorkflows` (#1804, M6). Admins only.
    static let consoleTeamWorkflows = "console/teamWorkflows"
    /// `Empty` → `LiveBoard` (#2019, M9). Admins only.
    static let consoleLive = "console/live"
    /// `ConsoleStopAgent` → `Empty` (#2019, M9). Admins only.
    static let consoleStopAgent = "console/stopAgent"
}
