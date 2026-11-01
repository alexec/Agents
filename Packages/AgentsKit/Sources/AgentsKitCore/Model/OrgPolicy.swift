import Foundation

/// The organisation's policy (#998, spec 998): one document of rules, kept by the control plane,
/// signed by its control key and followed by every machine as a ceiling over the person's and
/// the folder's own settings. The window and the Remote read it in Settings ▸ Control plane ▸
/// Policy; an admin edits it in Console ▸ Policy on the web page, and has the kill switch on
/// every client. The types are hand-written against `Packages/Wire/daemon.schema.json`
/// (`WireSchemaTests`); the words are `OrgPolicyWords`, the same as `Web/src/model/orgPolicy.ts`.
public extension DaemonAPI {
    /// One allowed runtime: the models allowed (absent = every model, `*` at the end allowed),
    /// and the ways it may reach the model (#999; absent = every way).
    struct PolicyRuntimeRule: Codable, Sendable, Hashable {
        public var models: [String]?
        public var reach: [String]?

        public init(models: [String]? = nil, reach: [String]? = nil) {
            self.models = models
            self.reach = reach
        }
    }

    /// The marketplaces allowed, by #687's ids, and whether an MCP server added by hand is.
    struct PolicyMarketplaces: Codable, Sendable, Hashable {
        public var allowed: [String]
        /// `allow` or `refuse`.
        public var customServers: String

        public init(allowed: [String], customServers: String) {
            self.allowed = allowed
            self.customServers = customServers
        }
    }

    /// An admin's raise of one person's budget for one UTC day.
    struct BudgetRaise: Codable, Sendable, Hashable {
        public var user: String
        /// YYYY-MM-DD, UTC.
        public var day: String
        public var daily: Double?
        public var dailyTokens: Int?
        public var by: AuditActor
        public var request: String?

        public init(user: String, day: String, daily: Double? = nil, dailyTokens: Int? = nil, by: AuditActor,
                    request: String? = nil) {
            self.user = user
            self.day = day
            self.daily = daily
            self.dailyTokens = dailyTokens
            self.by = by
            self.request = request
        }
    }

    /// Each person's budgets per UTC day and per agent, in US dollars and tokens.
    struct PolicyBudgets: Codable, Sendable, Hashable {
        public var daily: Double?
        public var dailyTokens: Int?
        public var perAgent: Double?
        public var perAgentTokens: Int?
        public var allowUnmetered: [String]
        public var raises: [BudgetRaise]

        public init(daily: Double? = nil, dailyTokens: Int? = nil, perAgent: Double? = nil, perAgentTokens: Int? = nil,
                    allowUnmetered: [String] = [], raises: [BudgetRaise] = []) {
            self.daily = daily
            self.dailyTokens = dailyTokens
            self.perAgent = perAgent
            self.perAgentTokens = perAgentTokens
            self.allowUnmetered = allowUnmetered
            self.raises = raises
        }
    }

    /// The ceiling over each folder's helper limits (#64).
    struct PolicyHelpers: Codable, Sendable, Hashable {
        public var mostRunning: Int?
        public var mostNotArchived: Int?

        public init(mostRunning: Int? = nil, mostNotArchived: Int? = nil) {
            self.mostRunning = mostRunning
            self.mostNotArchived = mostNotArchived
        }
    }

    /// The variable names a person's own pass-through list may name (#727), `*` at the end allowed.
    struct PolicyEnvironment: Codable, Sendable, Hashable {
        public var passThrough: [String]

        public init(passThrough: [String]) {
            self.passThrough = passThrough
        }
    }

    /// The notices a policy decides for every member (#999).
    struct PolicyNotices: Codable, Sendable, Hashable {
        /// `show` (as absent), `accepted` or `refuse`.
        public var antigravityTerms: String?

        public init(antigravityTerms: String? = nil) {
            self.antigravityTerms = antigravityTerms
        }
    }

    /// The kill switch: while on, every machine stops its turns and starts no work.
    struct PolicyStopAll: Codable, Sendable, Hashable {
        public var on: Bool
        public var by: AuditActor
        public var at: Date
        public var note: String?

        public init(on: Bool, by: AuditActor, at: Date, note: String? = nil) {
            self.on = on
            self.by = by
            self.at = at
            self.note = note
        }
    }

    /// The policy (spec 998 FR-002). Each rule is optional: absent sets no ceiling.
    struct OrgPolicy: Codable, Sendable, Hashable {
        public var version: Int
        public var issued: Date
        public var changedBy: AuditActor
        public var requires: [String]
        /// The loosest permission level, on Auto's four levels (#2957; it replaced `modeCeiling`, #3171).
        public var permissionMode: PermissionLevel?
        /// `required`, or absent for the person's choice.
        public var sandbox: String?
        public var runtimes: [String: PolicyRuntimeRule]?
        public var marketplaces: PolicyMarketplaces?
        public var budgets: PolicyBudgets?
        public var helpers: PolicyHelpers?
        public var environment: PolicyEnvironment?
        public var stopAll: PolicyStopAll?
        public var requireFollowing: Bool?
        public var groups: JSONValue?
        public var notices: PolicyNotices?

        public init(version: Int, issued: Date, changedBy: AuditActor, requires: [String] = [], permissionMode: PermissionLevel? = nil,
                    sandbox: String? = nil, runtimes: [String: PolicyRuntimeRule]? = nil,
                    marketplaces: PolicyMarketplaces? = nil, budgets: PolicyBudgets? = nil, helpers: PolicyHelpers? = nil,
                    environment: PolicyEnvironment? = nil, stopAll: PolicyStopAll? = nil, requireFollowing: Bool? = nil,
                    groups: JSONValue? = nil, notices: PolicyNotices? = nil) {
            self.version = version
            self.issued = issued
            self.changedBy = changedBy
            self.requires = requires
            self.permissionMode = permissionMode
            self.sandbox = sandbox
            self.runtimes = runtimes
            self.marketplaces = marketplaces
            self.budgets = budgets
            self.helpers = helpers
            self.environment = environment
            self.stopAll = stopAll
            self.requireFollowing = requireFollowing
            self.groups = groups
            self.notices = notices
        }

        /// Whether the kill switch is on.
        public var isStopped: Bool { stopAll?.on == true }
    }

    /// `policy/mine` and `control/policyChanged`: the policy in force, with only the caller's
    /// raises. No policy when none was ever set.
    struct PolicyView: Codable, Sendable, Hashable {
        public var policy: OrgPolicy?

        public init(policy: OrgPolicy? = nil) {
            self.policy = policy
        }
    }

    /// `policy/get`: the whole policy and its store tag, for an admin, with each machine's
    /// applied version by host id.
    struct PolicyKept: Codable, Sendable, Hashable {
        public var policy: OrgPolicy?
        public var rev: String?
        public var machines: [String: Int]?

        public init(policy: OrgPolicy? = nil, rev: String? = nil, machines: [String: Int]? = nil) {
            self.policy = policy
            self.rev = rev
            self.machines = machines
        }
    }

    /// `policy/set`: the rules, and the tag the admin read.
    struct PolicySet: Codable, Sendable, Hashable {
        public var policy: OrgPolicy
        public var rev: String?

        public init(policy: OrgPolicy, rev: String? = nil) {
            self.policy = policy
            self.rev = rev
        }
    }

    /// `policy/stopAll`: the kill switch on or off.
    struct PolicyStopAllRequest: Codable, Sendable, Hashable {
        public var on: Bool
        public var note: String?

        public init(on: Bool, note: String? = nil) {
            self.on = on
            self.note = note
        }
    }

    /// `policy/raise`: an admin raises a person's budget for today (UTC).
    struct PolicyRaiseRequest: Codable, Sendable, Hashable {
        public var user: String
        public var daily: Double?
        public var dailyTokens: Int?
        public var request: String?

        public init(user: String, daily: Double? = nil, dailyTokens: Int? = nil, request: String? = nil) {
            self.user = user
            self.daily = daily
            self.dailyTokens = dailyTokens
            self.request = request
        }
    }

    /// The mark on a choice the policy refuses or caps (FR-010), on the lists a machine sends.
    struct PolicySetBy: Codable, Sendable, Hashable {
        /// `organisation`, `you` or `folder`: the layer that decided (#2957, R8).
        public var by: String
        /// The rule's name, such as `permissionMode` or `runtimes.codex.models`.
        public var rule: String
        public var words: String
        /// The layer that decided, with its name (#2957, R8).
        public var layer: PolicyLayerRef?

        public init(by: String = "organisation", rule: String, words: String, layer: PolicyLayerRef? = nil) {
            self.by = by
            self.rule = rule
            self.words = words
            self.layer = layer
        }

        /// **Set by you**, **Set by this folder** or **Set by your organisation**, from the layer
        /// that decided (#3150).
        public var title: String { OrgPolicyWords.layerTitle(layer?.kind ?? by) }

        /// The layer's symbol beside the title.
        public var symbol: String { OrgPolicyWords.layerSymbol(layer?.kind ?? by) }
    }

    /// The data of a `policyRefused` error (FR-010): why, the rule, and the words.
    struct PolicyRefusal: Codable, Sendable, Hashable {
        /// `policy`, `budget`, `stopAll`, `noPolicy`, `mustJoin` or `update`.
        public var reason: String
        public var rule: String?
        public var words: String
        public var until: Date?
        /// The layer that decided, when the machine names one (#2957, R8); absent for the
        /// organisation's own refusals.
        public var layer: PolicyLayerRef?
        /// What that layer allows.
        public var value: String?

        public init(reason: String, rule: String? = nil, words: String, until: Date? = nil,
                    layer: PolicyLayerRef? = nil, value: String? = nil) {
            self.reason = reason
            self.rule = rule
            self.words = words
            self.until = until
            self.layer = layer
            self.value = value
        }

        /// The refusal in a `policyRefused` error, or nil for any other error.
        public init?(error: Error) {
            guard let rpc = error as? JSONRPCError, rpc.code == DaemonAPI.Failure.policyRefused,
                  let refusal = try? rpc.data?.decode(PolicyRefusal.self)
            else { return nil }
            self = refusal
        }

        /// The title over the words: **Set by your organisation**, or **Set by you** or **Set by
        /// this folder** for those layers' refusals (#3150), except where the words say what to do
        /// (`noPolicy`, `mustJoin`).
        public var title: String? {
            ["noPolicy", "mustJoin"].contains(reason) ? nil : OrgPolicyWords.layerTitle(layer?.kind)
        }

        /// The layer's symbol beside the title.
        public var symbol: String { OrgPolicyWords.layerSymbol(layer?.kind) }

        /// The title and the words, as one line.
        public var line: String {
            title.map { "\($0). \(words)" } ?? words
        }
    }
}

public extension DaemonAPI {
    /// `daemon/policyState` and `daemon/policyStateChanged` (#998, T027): the policy as this
    /// machine follows it. The clients draw the red strip and the composer's reason from it.
    struct PolicyState: Codable, Sendable, Hashable {
        /// Absent when this machine has no policy.
        public var version: Int?
        public var policy: OrgPolicy?
        /// The kill switch is on: this machine stops its turns and starts no work.
        public var stopAll: Bool
        /// This machine had a policy and has none it can trust now. It starts no work.
        public var noPolicy: Bool
        /// The capabilities the policy requires that this machine lacks (FR-014).
        public var update: [String]?
        /// Why this machine starts no work now, when it starts none.
        public var refusal: PolicyRefusal?

        public init(version: Int? = nil, policy: OrgPolicy? = nil, stopAll: Bool = false, noPolicy: Bool = false,
                    update: [String]? = nil, refusal: PolicyRefusal? = nil) {
            self.version = version
            self.policy = policy
            self.stopAll = stopAll
            self.noPolicy = noPolicy
            self.update = update
            self.refusal = refusal
        }

        /// Whether this machine starts no work now: the kill switch, no policy it can trust, or
        /// a capability it lacks.
        public var startsNothing: Bool { stopAll || noPolicy || !(update ?? []).isEmpty || refusal != nil }

        /// Why the composer cannot send, in the machine's words, or nil when it can.
        public var composerReason: String? {
            if let refusal { return refusal.line }
            if stopAll { return "\(OrgPolicyWords.setBy). \(OrgPolicyWords.stoppedStrip)" }
            return nil
        }
    }

    /// One name in the person's own pass-through list (#998, FR-011a).
    struct PassThroughName: Codable, Sendable, Hashable, Identifiable {
        /// A variable's name, or a prefix ending in `*`.
        public var name: String
        /// The runtime it is passed to; absent for every runtime.
        public var runtime: String?
        /// Set when the policy does not allow the name: it is not passed.
        public var setBy: PolicySetBy?

        public var id: String { "\(runtime ?? "*")/\(name)" }

        public init(name: String, runtime: String? = nil, setBy: PolicySetBy? = nil) {
            self.name = name
            self.runtime = runtime
            self.setBy = setBy
        }
    }

    /// `settings/passThrough` (#998): the person's own pass-through names, each marked when the
    /// policy refuses it.
    struct PassThroughState: Codable, Sendable, Hashable {
        public var names: [PassThroughName]

        public init(names: [PassThroughName] = []) {
            self.names = names
        }

        /// The names passed to one runtime: its own, and those for every runtime.
        public func names(for runtimeID: String) -> [PassThroughName] {
            names.filter { $0.runtime == nil || $0.runtime == runtimeID }
        }
    }
}

public extension DaemonAPI.Failure {
    /// A choice the organisation's policy refuses (#998). `data`: `PolicyRefusal`.
    static let policyRefused = -32076
}

public extension DaemonAPI.Method {
    /// `Empty` → `PolicyView`: the policy in force, for any person (#998).
    static let policyMine = "policy/mine"
    /// `Empty` → `PolicyKept`: an admin's (#998).
    static let policyGet = "policy/get"
    /// `PolicySet` → `PolicyKept`: an admin's (#998).
    static let policySet = "policy/set"
    /// `PolicyStopAllRequest` → `PolicyKept`: the kill switch, an admin's (#998).
    static let policyStopAll = "policy/stopAll"
    /// `PolicyRaiseRequest` → `PolicyKept`: an admin's (#998).
    static let policyRaise = "policy/raise"
    /// `Empty` → `PolicyState`: the policy as this machine follows it (#998, T027).
    static let daemonPolicyState = "daemon/policyState"
    /// `Empty` → `PassThroughState`: the person's pass-through names, marked (#998).
    static let settingsPassThrough = "settings/passThrough"
}

public extension DaemonAPI.Notification {
    /// `PolicyView`: the policy changed (#998).
    static let controlPolicyChanged = "control/policyChanged"
    /// `PolicyView`: the kill switch went on or off (#998).
    static let controlStopAll = "control/stopAll"
    /// `PolicyState`: the policy this machine follows changed, or the kill switch turned (#998).
    static let daemonPolicyStateChanged = "daemon/policyStateChanged"
}

/// The words of the organisation's policy, on the Mac and the Remote (`Web/src/model/orgPolicy.ts`
/// says the same on the web page). The machine's own refusals carry their words
/// (`PolicyRefusal`, `PolicySetBy`); these are the pane's.
public enum OrgPolicyWords {
    public static let setBy = "Set by your organisation"
    public static let title = "Policy"
    public static let symbol = "building.columns"
    /// The titles of a limit from the person's own layer and from a folder's (#2957, #3150).
    public static let setByYou = "Set by you"
    public static let setByFolder = "Set by this folder"
    public static let none = "Your organisation sets no policy."
    public static let editInConsole = "Edit in Console"
    /// Over the person's pass-through names (`runtime-environment.json`).
    public static let passThroughTitle = "Variables passed to it"
    /// Under the budgets on Cost, when no budget is reached and none caps a limit of the person's.
    public static let budgetFoot = "Your organisation’s budget. A lower limit of your own still applies."
    public static let foot = "Your organisation’s admins set these rules in Console ▸ Policy. Every machine follows them, also offline. A rule only caps your own settings: they come back when the rule does."

    // The kill switch (spec 998 US5).
    public static let stopAll = "Stop All Agent Work"
    public static let resumeAll = "Resume Agent Work"
    public static let stoppedStrip = "Your organisation has stopped all agent work."
    public static let stopTitle = "Stop all agent work?"
    public static let resumeTitle = "Resume agent work?"
    public static let resumeMessage = "Nothing starts again by itself. Each person sends their next prompt, and paused workflows run at their next trigger."
    public static let stopFoot = "For an incident, such as a leaked key or a runaway cost. Every machine stops at once, also those of bots."

    /// "This stops the 3 agents running now on every machine, …".
    public static func stopMessage(running: Int?) -> String {
        let now: String = switch running {
        case nil: "This stops every agent running now on every machine"
        case 0?: "No agent is running now. This stops every machine from starting one"
        case 1?: "This stops the 1 agent running now"
        case let n?: "This stops the \(n) agents running now"
        }
        return now + ", refuses new agents and prompts, and pauses every workflow, until an admin resumes agent work. Agents and their conversations are kept."
    }

    /// "Stopped by Priya at 02:04."
    public static func stoppedBy(_ stop: DaemonAPI.PolicyStopAll, now: Date = .now) -> String {
        "Stopped by \(name(stop.by)) \(when(stop.at, now: now))."
    }

    /// "Version 4, changed by Priya on 21 Oct at 14:05."
    public static func changed(_ policy: DaemonAPI.OrgPolicy, now: Date = .now) -> String {
        "Version \(policy.version), changed by \(name(policy.changedBy)) \(when(policy.issued, now: now))."
    }

    /// The actor's name, or their id.
    public static func name(_ actor: DaemonAPI.AuditActor) -> String {
        actor.userName.flatMap { $0.isEmpty ? nil : $0 } ?? actor.user
    }

    /// "at 14:05" today, "on 21 Oct at 14:05" before.
    static func when(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time)" }
        let day = date.formatted(.dateTime.day().month(.abbreviated))
        return "on \(day) at \(time)"
    }

    /// RuntimeCatalog's names, for a runtime this client may not be told about.
    public static let runtimeNames: [String: String] = [
        "claude": "Claude", "codex": "Codex", "cursor": "Cursor", "copilot": "Copilot",
        "antigravity": "Antigravity", "opencode": "OpenCode", "grok": "Grok",
    ]

    public static func runtimeName(_ id: String) -> String { runtimeNames[id] ?? id }

    /// "$40" or "$40.50".
    public static func dollars(_ amount: Double) -> String {
        amount == amount.rounded() ? "$\(Int(amount))" : String(format: "$%.2f", amount)
    }

    /// "50,000 tokens".
    public static func tokens(_ count: Int) -> String {
        "\(count.formatted(.number.locale(Locale(identifier: "en_GB")))) tokens"
    }

    /// One rule, in words, for the read-only pane.
    public struct Rule: Hashable, Sendable, Identifiable {
        public var name: String
        public var title: String
        public var words: String
        public var id: String { name }
    }

    /// Each rule the policy sets, in the pane's order. Empty for a policy that sets none.
    public static func rules(_ policy: DaemonAPI.OrgPolicy) -> [Rule] {
        var out: [Rule] = []
        if let mode = policy.permissionMode {
            out.append(Rule(name: "permissionMode", title: "Modes", words: "Up to \(LevelWords.permission(mode))"))
        }
        if policy.sandbox == "required" {
            out.append(Rule(name: "sandbox", title: "Command sandbox", words: "Required"))
        }
        if let runtimes = policy.runtimes {
            out.append(Rule(name: "runtimes", title: "Runtimes", words: runtimeWords(runtimes)))
            // Each runtime's ways to the model (#999).
            for id in runtimes.keys.sorted(by: { runtimeName($0) < runtimeName($1) }) {
                guard let reach = runtimes[id]?.reach else { continue }
                out.append(Rule(name: "runtimes.\(id).reach", title: "\(runtimeName(id)) reaches the model by",
                                words: OrgAccountWords.reachWords(reach)))
            }
        }
        if let marketplaces = policy.marketplaces {
            let allowed = marketplaces.allowed.isEmpty ? "None" : "Only \(marketplaces.allowed.sorted().joined(separator: ", "))"
            out.append(Rule(name: "marketplaces", title: "Marketplaces", words: allowed))
            out.append(Rule(name: "marketplaces.customServers", title: "MCP servers added by hand",
                            words: marketplaces.customServers == "refuse" ? "Not allowed" : "Allowed"))
        }
        if let budgets = policy.budgets, let words = budgetWords(budgets) {
            out.append(Rule(name: "budgets", title: "Budget", words: words))
            if !budgets.allowUnmetered.isEmpty {
                out.append(Rule(name: "budgets.allowUnmetered", title: "Unmetered runtimes",
                                words: "Allowed: " + budgets.allowUnmetered.map(runtimeName).sorted().joined(separator: ", ")))
            }
        }
        if let helpers = policy.helpers, let words = helperWords(helpers) {
            out.append(Rule(name: "helpers", title: "Helper sessions", words: words))
        }
        if let environment = policy.environment {
            let names = environment.passThrough
            out.append(Rule(name: "environment.passThrough", title: "Variables passed to runtimes",
                            words: names.isEmpty ? "None" : "Only \(names.sorted().joined(separator: ", "))"))
        }
        if let terms = policy.notices?.antigravityTerms, terms != "show" {
            out.append(Rule(name: "notices.antigravityTerms", title: "Antigravity’s terms",
                            words: terms == "refuse" ? "Antigravity is not allowed" : "Reviewed by your organisation"))
        }
        if policy.requireFollowing == true {
            out.append(Rule(name: "requireFollowing", title: "Machines",
                            words: "A machine that does not follow this policy starts no agent"))
        }
        return out
    }

    /// "Claude (claude-sonnet-*), Codex".
    static func runtimeWords(_ runtimes: [String: DaemonAPI.PolicyRuntimeRule]) -> String {
        if runtimes.isEmpty { return "None" }
        // Each runtime named for its ways to the model only (#999).
        if runtimeNames.keys.allSatisfy({ runtimes[$0] != nil && runtimes[$0]?.models == nil }) { return "Every runtime" }
        return "Only " + runtimes.keys.sorted { runtimeName($0) < runtimeName($1) }.map { id in
            let name = runtimeName(id)
            guard let models = runtimes[id]?.models else { return name }
            return models.isEmpty ? "\(name) (no models)" : "\(name) (\(models.joined(separator: ", ")))"
        }.joined(separator: ", ")
    }

    /// "$40 a day, 50,000 tokens a day, $5 an agent"; nil when no number is set.
    public static func budgetWords(_ b: DaemonAPI.PolicyBudgets) -> String? {
        var parts: [String] = []
        if let d = b.daily { parts.append("\(dollars(d)) a day") }
        if let t = b.dailyTokens { parts.append("\(tokens(t)) a day") }
        if let d = b.perAgent { parts.append("\(dollars(d)) an agent") }
        if let t = b.perAgentTokens { parts.append("\(tokens(t)) an agent") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// "At most 3 running and 10 not archived in a folder"; nil when neither is set.
    public static func helperWords(_ h: DaemonAPI.PolicyHelpers) -> String? {
        var parts: [String] = []
        if let n = h.mostRunning { parts.append("\(n) running") }
        if let n = h.mostNotArchived { parts.append("\(n) not archived") }
        return parts.isEmpty ? nil : "At most \(parts.joined(separator: " and ")) in a folder"
    }

    /// Console ▸ Policy on the web page, for **Edit in Console**: on the control plane's own domain
    /// when it serves the page there, else where this Mac serves it. Nil when it is served nowhere.
    public static func consoleURL(_ status: DaemonAPI.ControlStatus?) -> URL? {
        let page = status?.publicWeb ?? status?.web.flatMap { $0.served ? $0.address : nil }
        guard let page, !page.isEmpty else { return nil }
        let base = page.hasSuffix("/") ? String(page.dropLast()) : page
        return URL(string: "\(base)/#/console/policy")
    }

    /// The running agents each machine last listed, or nil when none ever listed them.
    public static func running(_ board: DaemonAPI.FleetBoard?) -> Int? {
        let counts = (board?.machines ?? []).compactMap(\.running)
        return counts.isEmpty ? nil : counts.reduce(0, +)
    }

    /// The organisation's budgets in force for this person today (`CostState.organisation`, with
    /// any raise), as rows beside the person's own limits on Cost: "Per day", "$40". Empty with none.
    public static func budgetRows(_ limits: CostLimits?) -> [Rule] {
        guard let limits else { return [] }
        var out: [Rule] = []
        if let d = limits.daily {
            out.append(Rule(name: "budgets.daily", title: "Per day", words: d.amount.formatted(.currency(code: d.currency))))
        }
        if let t = limits.dailyTokens { out.append(Rule(name: "budgets.dailyTokens", title: "Tokens per day", words: tokens(t))) }
        if let a = limits.perAgent {
            out.append(Rule(name: "budgets.perAgent", title: "Per agent", words: a.amount.formatted(.currency(code: a.currency))))
        }
        if let t = limits.perAgentTokens {
            out.append(Rule(name: "budgets.perAgentTokens", title: "Tokens per agent", words: tokens(t)))
        }
        return out
    }

    /// The mark on **Add by Hand** while the policy refuses MCP servers added by hand, in the
    /// machine's words (`agentsd`'s refusal of `mcp/add-by-hand`); nil while it allows them.
    public static func customServersMark(_ policy: DaemonAPI.OrgPolicy?) -> DaemonAPI.PolicySetBy? {
        guard policy?.marketplaces?.customServers == "refuse" else { return nil }
        return DaemonAPI.PolicySetBy(rule: "marketplaces.customServers",
                                     words: "Your organisation does not allow MCP servers added by hand.")
    }

    /// The title for the layer that decided (`PolicyLayerRef.kind`): the organisation's when none
    /// is named (#3150).
    public static func layerTitle(_ kind: String?) -> String {
        switch kind {
        case "you": setByYou
        case "folder": setByFolder
        default: setBy
        }
    }

    /// The symbol for the layer that decided: a person, a folder, or the organisation's building.
    public static func layerSymbol(_ kind: String?) -> String {
        switch kind {
        case "you": "person"
        case "folder": "folder"
        default: symbol
        }
    }

    /// The line under a refused choice: the mark's words, under its layer's title (**Set by your
    /// organisation**, **Set by you** or **Set by this folder**).
    public static func line(_ mark: DaemonAPI.PolicySetBy) -> String {
        "\(mark.title). \(mark.words)"
    }
}
