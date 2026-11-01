import Foundation

/// The words and the rows of Agents ▸ Policy (#2957, FR-019 to FR-021; contracts/
/// policy-layers-api.md "Client words"), on the Mac and the Remote. `Web/src/model/
/// policyLayers.ts` says the same on the web page. The machine resolves the layers and sends
/// each rule's words and cap line (`EffectiveRule`); these are the pane's own: the sections,
/// the titles, what a menu offers, and which of its values a cap dims.
public enum PolicyLayersWords {
    /// The Settings group (FR-018) and its pane.
    public static let groupTitle = "Agents"
    public static let title = "Policy"
    public static let symbol = "checklist"
    /// Control plane ▸ Policy's new name (FR-024).
    public static let organisationTitle = "Organisation Policy"

    public static let notSet = "Not set"
    public static let keptNotUsed = "Kept, not used"
    public static let sameAsYours = "Same as yours"
    public static let cappedByYours = "Capped by yours"
    public static let whereFrom = "Where this comes from"
    public static let decides = "Decides"
    public static let folderFile = "committed with the folder’s code"
    public static let toolsFoot = "Agent Runtimes and Connectors set these up. Here you see what the layers allow."
    public static let foot = "Agents, helpers and workflows can’t change these. Each rule only gets tighter from layer to layer: the tightest value applies."

    /// The banner's first line (FR-021): who sets limits above yours, or no one.
    public static func banner(_ policy: DaemonAPI.EffectivePolicy) -> String {
        if let organisation = policy.organisation { return "\(organisation) sets limits above yours" }
        return "You set every limit"
    }

    /// The banner's second line for a person alone: how many folders set their own rules.
    public static func foldersLine(_ count: Int) -> String {
        switch count {
        case 0: "No folder has its own rules."
        case 1: "1 folder has its own rules."
        default: "\(count) folders have their own rules."
        }
    }

    /// The machines that do not follow the layers yet (Edge Cases, "A machine of an older
    /// version"); nil with none.
    public static func behindLine(_ machines: [DaemonAPI.PolicyBehindMachine]) -> String? {
        guard !machines.isEmpty else { return nil }
        let names = machines.map(\.name).sorted().joined(separator: ", ")
        return "\(names) \(machines.count == 1 ? "does" : "do") not follow your policy yet. Update \(machines.count == 1 ? "it" : "them") to the newest version."
    }

    /// How "Where this comes from" names a layer: the folder's by its file.
    public static func layerLine(_ layer: DaemonAPI.PolicyLayerRef) -> String {
        switch layer.kind {
        case "you": "You"
        case "folder": "\(layer.name) (.agents/policy.json)"
        default: layer.name
        }
    }

    // MARK: The rows

    public enum Section: String, CaseIterable, Sendable {
        case permissions, money, workAtOnce, attention, tools

        public var title: String {
            switch self {
            case .permissions: "Permissions"
            case .money: "Money"
            case .workAtOnce: "Work at once"
            case .attention: "Your attention"
            case .tools: "Tools"
            }
        }
    }

    /// How a row is edited. A choice lists its values loosest first; a number is tighter
    /// when lower, unless `higherIsTighter`.
    public enum Kind: Hashable, Sendable {
        case choice([String])
        case money
        case tokens
        case count([Int], higherIsTighter: Bool)
        case toggle
        /// Read only on this pane: Agent Runtimes and Connectors set these up.
        case list
    }

    public struct Row: Hashable, Sendable, Identifiable {
        public var rule: String
        public var title: String
        public var section: Section
        public var kind: Kind
        /// What applies when no layer sets it (data-model.md "Unset means").
        public var unset: String
        public var id: String { rule }
    }

    public static let rows: [Row] = [
        Row(rule: "permissionMode", title: "Permission mode", section: .permissions,
            kind: .choice(["bypassPermissions", "approveForMe", "ask", "plan"]), unset: "Ask, and any mode may be chosen"),
        Row(rule: "permissionRequests", title: "Permission requests", section: .permissions,
            kind: .choice(["alwaysApprove", "default"]), unset: "Each runtime’s"),
        Row(rule: "sandbox", title: "Sandbox", section: .permissions,
            kind: .choice(["off", "runtime", "on"]), unset: "Each runtime’s"),
        Row(rule: "budgets.perAgent", title: "Per agent", section: .money, kind: .money, unset: "No limit"),
        Row(rule: "budgets.perAgentTokens", title: "Tokens per agent", section: .money, kind: .tokens, unset: "No limit"),
        Row(rule: "budgets.daily", title: "Per day", section: .money, kind: .money, unset: "No limit"),
        Row(rule: "budgets.dailyTokens", title: "Tokens per day", section: .money, kind: .tokens, unset: "No limit"),
        Row(rule: "helpers.mostRunning", title: "Helpers running in each folder", section: .workAtOnce,
            kind: .count(Array(1...10), higherIsTighter: false), unset: "3"),
        Row(rule: "helpers.mostNotArchived", title: "Helpers not archived in each folder", section: .workAtOnce,
            kind: .count(Array(1...20), higherIsTighter: false), unset: "5"),
        Row(rule: "workflows.mostOn", title: "Workflows turned on in each folder", section: .workAtOnce,
            kind: .count(Array(1...100), higherIsTighter: false), unset: "20"),
        Row(rule: "noticeLimits.burst", title: "Notices in a burst", section: .attention,
            kind: .count(Array(1...20), higherIsTighter: false), unset: "3"),
        Row(rule: "noticeLimits.waitMinutes", title: "Wait after a burst", section: .attention,
            kind: .count(DisplayPreference.noticeCooldownPresets, higherIsTighter: true), unset: "10 minutes"),
        Row(rule: "archiveMyChats", title: "Agents may archive the chats I start", section: .attention,
            kind: .toggle, unset: "On"),
        Row(rule: "runtimes", title: "Runtimes and models", section: .tools, kind: .list, unset: "Every runtime and model"),
        Row(rule: "marketplaces.allowed", title: "Marketplaces", section: .tools, kind: .list, unset: "Every marketplace"),
        Row(rule: "marketplaces.customServers", title: "Connectors added by hand", section: .tools,
            kind: .list, unset: "Allowed"),
        Row(rule: "environment", title: "Variables agents get", section: .tools, kind: .list, unset: "Each runtime’s own"),
    ]

    public static func rows(in section: Section) -> [Row] { rows.filter { $0.section == section } }

    /// A choice's words, as the machine says them (`policylayers`' words).
    public static func choice(_ rule: String, _ raw: String) -> String {
        switch (rule, raw) {
        case ("permissionMode", _): PermissionLevel(rawValue: raw).map(LevelWords.permission) ?? raw
        case ("permissionRequests", "default"): "Ask me"
        case ("permissionRequests", "alwaysApprove"): "Approve for me"
        case ("sandbox", "off"): "Off allowed"
        case ("sandbox", "runtime"): "The runtime’s"
        case ("sandbox", "on"): "On"
        default: raw
        }
    }

    /// A number's words in a menu: minutes as the notice menu says them.
    public static func count(_ rule: String, _ n: Int) -> String {
        rule == "noticeLimits.waitMinutes" ? minutes(n) : "\(n)"
    }

    /// "10 min", "1 hour", "4 hours": the notice menu's words (`NotificationLimitsSection`).
    public static func minutes(_ minutes: Int) -> String {
        guard minutes >= 60, minutes % 60 == 0 else { return "\(minutes) min" }
        let hours = minutes / 60
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    // MARK: Typed limits

    /// A money value as its field shows it: "40" or "40.5".
    public static func amountWords(_ value: JSONValue) -> String? {
        amount(value).map { $0 == $0.rounded() ? String(Int($0)) : String($0) }
    }

    /// What a money field's text sets: nil for text that is no amount, so nothing is saved;
    /// `.some(nil)` for an empty field, which is no limit, never a zero.
    public static func moneyValue(_ text: String) -> JSONValue?? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        if t.isEmpty { return .some(nil) }
        guard let v = Double(t), v >= 0 else { return nil }
        return .some(.object(["amount": .double(v), "currency": .string("USD")]))
    }

    /// What a token field's text sets, on the same terms; grouping ("2,000,000") is taken out.
    public static func tokensValue(_ text: String) -> JSONValue?? {
        let digits = text.filter { !$0.isWhitespace && $0 != "," && $0 != "_" && $0 != "." }
        if digits.isEmpty { return .some(nil) }
        guard let v = Int(digits), v >= 1 else { return nil }
        return .some(.int(v))
    }

    // MARK: Caps

    /// Whether `value` is looser than `cap` by the rule's order (FR-004), so a menu dims it.
    /// False with no cap, and for a value the order does not know.
    public static func isLooser(_ row: Row, _ value: JSONValue, than cap: JSONValue?) -> Bool {
        guard let cap else { return false }
        switch row.kind {
        case .choice(let order):
            guard let v = value.stringValue.flatMap(order.firstIndex), let c = cap.stringValue.flatMap(order.firstIndex) else { return false }
            return v < c
        case .money:
            guard let v = amount(value), let c = amount(cap) else { return false }
            return v > c
        case .tokens:
            guard let v = number(value), let c = number(cap) else { return false }
            return v > c
        case .count(_, let higherIsTighter):
            guard let v = number(value), let c = number(cap) else { return false }
            return higherIsTighter ? v < c : v > c
        case .toggle:
            return value.boolValue == true && cap.boolValue == false
        case .list:
            return false
        }
    }

    static func amount(_ value: JSONValue) -> Double? {
        value.objectValue?["amount"].flatMap(number)
    }

    static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .int(let v): Double(v)
        case .double(let v): v
        default: nil
        }
    }

    /// Your own value is kept while a layer above caps it (FR-006): "Kept, not used".
    public static func yoursIsKept(_ rule: DaemonAPI.EffectiveRule) -> Bool {
        rule.layers.contains { $0.layer.kind == "you" && $0.kept }
    }

    // MARK: Reading and setting your layer

    /// The value a layer's rules set for a row, as the wire has it; nil when unset.
    public static func value(_ rules: DaemonAPI.PolicyRules, _ rule: String) -> JSONValue? {
        switch rule {
        case "permissionMode": rules.permissionMode.map { .string($0.rawValue) }
        case "permissionRequests": rules.permissionRequests.map { .string($0.rawValue) }
        case "sandbox": rules.sandbox.map { .string($0.rawValue) }
        case "budgets.perAgent": rules.budgets?.perAgent.map(money)
        case "budgets.daily": rules.budgets?.daily.map(money)
        case "budgets.perAgentTokens": rules.budgets?.perAgentTokens.map { .int($0) }
        case "budgets.dailyTokens": rules.budgets?.dailyTokens.map { .int($0) }
        case "helpers.mostRunning": rules.helpers?.mostRunning.map { .int($0) }
        case "helpers.mostNotArchived": rules.helpers?.mostNotArchived.map { .int($0) }
        case "workflows.mostOn": rules.workflows?.mostOn.map { .int($0) }
        case "noticeLimits.burst": rules.noticeLimits?.burst.map { .int($0) }
        case "noticeLimits.waitMinutes": rules.noticeLimits?.waitMinutes.map { .int($0) }
        case "archiveMyChats": rules.archiveMyChats.map { .bool($0) }
        default: nil
        }
    }

    static func money(_ cost: Cost) -> JSONValue {
        .object(["amount": .double(NSDecimalNumber(decimal: cost.amount).doubleValue), "currency": .string(cost.currency)])
    }

    /// `rules` with one row set to `value`, or unset with nil. An emptied group is dropped,
    /// so the layer keeps only the rules it sets (FR-014).
    public static func setting(_ rules: DaemonAPI.PolicyRules, _ rule: String, to value: JSONValue?) -> DaemonAPI.PolicyRules {
        var r = rules
        var budgets = r.budgets ?? DaemonAPI.PolicyRuleBudgets()
        var helpers = r.helpers ?? DaemonAPI.PolicyHelpers()
        var notices = r.noticeLimits ?? DaemonAPI.PolicyNoticeLimits()
        switch rule {
        case "permissionMode": r.permissionMode = value?.stringValue.flatMap(PermissionLevel.init)
        case "permissionRequests": r.permissionRequests = value?.stringValue.flatMap(ClientPermissionMode.init)
        case "sandbox": r.sandbox = value?.stringValue.flatMap(SandboxChoice.init)
        case "budgets.perAgent": budgets.perAgent = value.flatMap(cost)
        case "budgets.daily": budgets.daily = value.flatMap(cost)
        case "budgets.perAgentTokens": budgets.perAgentTokens = value?.intValue
        case "budgets.dailyTokens": budgets.dailyTokens = value?.intValue
        case "helpers.mostRunning": helpers.mostRunning = value?.intValue
        case "helpers.mostNotArchived": helpers.mostNotArchived = value?.intValue
        case "workflows.mostOn": r.workflows = value?.intValue.map { DaemonAPI.PolicyWorkflows(mostOn: $0) }
        case "noticeLimits.burst": notices.burst = value?.intValue
        case "noticeLimits.waitMinutes": notices.waitMinutes = value?.intValue
        // On is the default: only Off is a rule.
        case "archiveMyChats": r.archiveMyChats = value?.boolValue == false ? false : nil
        default: return rules
        }
        if rule.hasPrefix("budgets.") { r.budgets = budgets == DaemonAPI.PolicyRuleBudgets() ? nil : budgets }
        if rule.hasPrefix("helpers.") { r.helpers = helpers.mostRunning == nil && helpers.mostNotArchived == nil ? nil : helpers }
        if rule.hasPrefix("noticeLimits.") { r.noticeLimits = notices == DaemonAPI.PolicyNoticeLimits() ? nil : notices }
        return r
    }

    static func cost(_ value: JSONValue) -> Cost? {
        guard let amount = amount(value) else { return nil }
        let currency = value.objectValue?["currency"]?.stringValue ?? "USD"
        return Cost(amount: Decimal(string: String(amount)) ?? Decimal(amount), currency: currency)
    }
}
