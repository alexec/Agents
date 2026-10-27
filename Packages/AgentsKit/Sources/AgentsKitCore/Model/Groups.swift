import Foundation

/// Groups (#1761, spec 736 FR-027, FR-028): everyone, or named users. A group owns
/// machine providers: only its users see them and start machines from them. A provider
/// with no group is the admins' alone.
public extension DaemonAPI {
    /// A group, in `groups/list` and as `groups/set` answers.
    struct Group: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var everyone: Bool
        public var members: [String]
        /// Caps for the group's bots together (#1761, FR-033).
        public var caps: SpendCaps?
        /// A SCIM group's provider (#1002, FR-019). Nil for a group an admin made.
        public var source: GroupSource?
        /// "admin": the group gives its people the admin role (#1002, FR-020).
        public var role: String?

        public init(id: String, name: String, everyone: Bool = false, members: [String] = [], caps: SpendCaps? = nil,
                    source: GroupSource? = nil, role: String? = nil) {
            self.caps = caps
            self.source = source
            self.role = role
            self.id = id
            self.name = name
            self.everyone = everyone
            self.members = members
        }

        /// Whether it gives its people the admin role (FR-020).
        public var givesAdmin: Bool { role == "admin" }

        /// Says a user is in it.
        public func has(_ user: String) -> Bool { everyone || members.contains(user) }
    }

    /// Where a group comes from (#1002, FR-019): an org provider's SCIM, which alone changes its members.
    struct GroupSource: Codable, Sendable, Hashable {
        public var scim: String
        public var externalId: String?
        public var displayName: String

        public init(scim: String, externalId: String? = nil, displayName: String) {
            self.scim = scim
            self.externalId = externalId
            self.displayName = displayName
        }
    }

    /// `groups/list`: every group for an admin; for a member, the groups they are in.
    struct GroupList: Codable, Sendable, Hashable {
        public var groups: [Group]

        public init(groups: [Group] = []) { self.groups = groups }
    }

    /// `groups/set`: makes a group, or with `id` changes one.
    struct GroupSet: Codable, Sendable, Hashable {
        public var id: String?
        public var name: String
        public var everyone: Bool?
        public var members: [String]?
        /// Left out keeps the caps it had.
        public var caps: SpendCaps?

        public init(id: String? = nil, name: String, everyone: Bool? = nil, members: [String]? = nil,
                    caps: SpendCaps? = nil) {
            self.caps = caps
            self.id = id
            self.name = name
            self.everyone = everyone
            self.members = members
        }
    }

    /// `groups/remove`. Refused while a machine provider or a bot has the group.
    struct GroupRequest: Codable, Sendable, Hashable {
        public var id: String

        public init(id: String) { self.id = id }
    }

    /// `providers/setGroup`: no group is the admins' alone.
    struct ProviderGroup: Codable, Sendable, Hashable {
        public var provider: ProviderID
        public var group: String?

        public init(provider: ProviderID, group: String? = nil) {
            self.provider = provider
            self.group = group
        }
    }

    /// Spend caps (#1761, FR-033): a bot or a group starts no work once its spend today
    /// (UTC) reaches one. None is no cap.
    struct SpendCaps: Codable, Sendable, Hashable {
        public var dailyUSD: Double?

        public init(dailyUSD: Double? = nil) { self.dailyUSD = dailyUSD }
    }

    /// `bots/make` (#1761, FR-030): a bot, in a group, with caps.
    struct BotMake: Codable, Sendable, Hashable {
        public var name: String
        public var group: String
        public var caps: SpendCaps?

        public init(name: String, group: String, caps: SpendCaps? = nil) {
            self.name = name
            self.group = group
            self.caps = caps
        }
    }

    /// `bots/make`'s answer: the bot's user id.
    struct BotMade: Codable, Sendable, Hashable {
        public var user: String

        public init(user: String) { self.user = user }
    }

    /// `bots/setCaps`: the bot's caps, and optionally its group.
    struct BotCaps: Codable, Sendable, Hashable {
        public var user: String
        public var caps: SpendCaps
        public var group: String?

        public init(user: String, caps: SpendCaps, group: String? = nil) {
            self.user = user
            self.caps = caps
            self.group = group
        }
    }

    /// `bots/stopRun` (FR-031): an admin stops an agent on a bot's machine.
    struct BotStopRun: Codable, Sendable, Hashable {
        public var host: MachineRef
        public var agent: UUID

        public init(host: MachineRef, agent: UUID) {
            self.host = host
            self.agent = agent
        }
    }

    /// `hosts/startEnroll` with `as`: a code for a bot's machine, an admin's only (#1761).
    struct MachineEnroll: Codable, Sendable, Hashable {
        public var `as`: String?

        public init(as bot: String? = nil) { self.as = bot }
    }

    /// `control/capReached` (FR-033): to admins, a bot stopped starting work at a cap.
    struct CapReached: Codable, Sendable, Hashable {
        public var user: String
        public var name: String
        public var group: String?
        public var spentUSD: Double
        public var capUSD: Double
        public var until: Date

        public init(user: String, name: String, group: String? = nil, spentUSD: Double, capUSD: Double, until: Date) {
            self.user = user
            self.name = name
            self.group = group
            self.spentUSD = spentUSD
            self.capUSD = capUSD
            self.until = until
        }
    }

    /// `control/groupsChanged`: a group was made, changed or removed.
    struct GroupsChanged: Codable, Sendable, Hashable {
        public var id: String?
        public var removed: Bool?

        public init(id: String? = nil, removed: Bool? = nil) {
            self.id = id
            self.removed = removed
        }
    }
}

public extension DaemonAPI.Method {
    /// `Empty` → `GroupList` (#1761).
    static let groupsList = "groups/list"
    /// `GroupSet` → `Group`, an admin's only (#1761).
    static let groupsSet = "groups/set"
    /// `GroupRequest` → `{}`, an admin's only (#1761).
    static let groupsRemove = "groups/remove"
    /// `ProviderGroup` → `{}`, an admin's only (#1761).
    static let providersSetGroup = "providers/setGroup"
    /// `BotMake` → `BotMade`, an admin's only (#1761).
    static let botsMake = "bots/make"
    /// `BotCaps` → `{}`, an admin's only (#1761).
    static let botsSetCaps = "bots/setCaps"
    /// `BotStopRun` → `{}`, an admin's only (#1761).
    static let botsStopRun = "bots/stopRun"
}

public extension DaemonAPI.Notification {
    /// `GroupsChanged`: load Groups again (#1761).
    static let controlGroupsChanged = "control/groupsChanged"
    /// `CapReached`: a bot is at its cap (#1761).
    static let controlCapReached = "control/capReached"
}

/// The words Settings ▸ Groups and a provider's group are shown in, the same on the Mac and
/// the Remote (the web page's are in `Web/src/model/teamGroups.ts`).
public enum GroupWords {
    public static let title = "Groups"
    public static let givesAdmin = "Gives the admin role"
    /// A SCIM group's line (#1002, FR-031): "From Acme Okta", with " · Gives the admin role" when it does.
    public static func orgLine(_ group: DaemonAPI.Group, provider: String) -> String {
        group.givesAdmin ? "\(PeopleWords.fromProvider(provider)) · \(givesAdmin)" : PeopleWords.fromProvider(provider)
    }
    /// A provider with no group.
    public static let adminsOnly = "Admins only"

    /// "Everyone", "Sam, Kim", or "No one".
    public static func members(_ group: DaemonAPI.Group, people: [DaemonAPI.PersonRow]) -> String {
        if group.everyone { return "Everyone" }
        guard !group.members.isEmpty else { return "No one" }
        return group.members.map { id in people.first { $0.id == id }?.name ?? "Someone removed" }
            .joined(separator: ", ")
    }

    /// The bots in a group (#2132), which a bot names itself: "review-bot, nightly-bot", or "None".
    public static func bots(_ group: DaemonAPI.Group, people: [DaemonAPI.PersonRow]) -> String {
        let names = people.filter { $0.kind == .bot && $0.group == group.id }.map(\.name)
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    /// "DigitalOcean, Docker", or nil with none.
    public static func providers(_ group: DaemonAPI.Group, of all: [DaemonAPI.ProviderSummary]) -> String? {
        let names = all.filter { $0.group == group.id }.map(\.name)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// Who a provider is for: its group's name, or the admins alone.
    public static func provider(_ provider: DaemonAPI.ProviderSummary, groups: [DaemonAPI.Group]) -> String {
        guard let id = provider.group, !id.isEmpty else { return adminsOnly }
        return groups.first { $0.id == id }?.name ?? "A group not shown to you"
    }

    /// "For Platform": a provider's line, said only when there are groups.
    public static func providerLine(_ provider: DaemonAPI.ProviderSummary, groups: [DaemonAPI.Group]) -> String? {
        guard !groups.isEmpty || provider.group != nil else { return nil }
        guard provider.group?.isEmpty == false else { return "For admins only" }
        return "For \(self.provider(provider, groups: groups))"
    }

    /// Why New Machine… is not there for a provider the caller sees but may not use.
    public static func mayNotUse(_ provider: DaemonAPI.ProviderSummary, groups: [DaemonAPI.Group]) -> String {
        guard let id = provider.group, !id.isEmpty else {
            return "Give \(provider.name) to a group to start machines from it."
        }
        let name = groups.first { $0.id == id }?.name ?? "its group"
        return "Only \(name) can start machines from \(provider.name)."
    }

    public static func foot(admin: Bool) -> String {
        admin
            ? "A group is everyone, or the people you name. Give a machine provider to a group, and only its people see it and start machines from it. A provider with no group is for admins only."
            : "The groups you are in. Their machine providers are the ones you can start machines from."
    }

    public static func removeTitle(_ group: DaemonAPI.Group) -> String { "Remove \(group.name)?" }

    /// A group's daily cap and its bots' spend today, together (#2074): "$50 a day · $12 today",
    /// or "No cap". The control plane weighs the group's bots together against it.
    public static func capLine(_ group: DaemonAPI.Group, people: [DaemonAPI.PersonRow]) -> String {
        let spent = people.filter { $0.kind == .bot && $0.group == group.id }.compactMap(\.spentTodayUSD)
        var parts = [BotWords.cap(group.caps)]
        // To the cent, so $3.20 and $8.80 make $12.
        if !spent.isEmpty { parts.append("\(BotWords.dollars((spent.reduce(0, +) * 100).rounded() / 100)) today") }
        return parts.joined(separator: " · ")
    }

    public static let capFoot = "Its bots together stop starting work at it, until midnight UTC."

    public static let removeMessage = "Its people keep their machines. A provider must go to another group first."
}

/// The words a bot is shown in, in Settings ▸ People (#1761), the same on the Mac and the
/// Remote (the web page's are in `Web/src/model/teamGroups.ts`).
public enum BotWords {
    /// Settings ▸ Control plane ▸ Bots (#2132), a pane of its own next to People.
    public static let title = "Bots"
    public static let empty = "No bots yet. A bot runs workflows as its own user, in one group, with a daily cap."
    public static let make = "Make a Bot…"
    public static let addMachine = "Add a Machine…"
    public static let setCap = "Group and Cap…"

    /// "$50 a day", or "No cap".
    public static func cap(_ caps: DaemonAPI.SpendCaps?) -> String {
        guard let usd = caps?.dailyUSD, usd > 0 else { return "No cap" }
        return "\(dollars(usd)) a day"
    }

    /// "In Platform · $50 a day · $3.20 today".
    public static func line(_ bot: DaemonAPI.PersonRow, groups: [DaemonAPI.Group]) -> String {
        let group = groups.first { $0.id == bot.group }?.name ?? "a group not shown to you"
        var parts = ["In \(group)", cap(bot.caps)]
        if let spent = bot.spentTodayUSD { parts.append("\(dollars(spent)) today") }
        return parts.joined(separator: " · ")
    }

    /// The notice an admin is shown when a bot stopped at a cap.
    public static func capReached(_ reached: DaemonAPI.CapReached) -> String {
        let whose = reached.group.map { "\($0)’s cap" } ?? "its cap"
        return "\(reached.name) stopped at \(whose): \(dollars(reached.spentUSD)) of \(dollars(reached.capUSD)) today. It starts work again at midnight UTC."
    }

    /// The sidebar card's heading for a bot at its cap (#2073).
    public static func capReachedTitle(_ reached: DaemonAPI.CapReached) -> String { "\(reached.name) stopped at its cap" }

    public static let foot = "A bot runs the team’s workflows: a workflow whose runs-on: names it runs on its machines, once per trigger. Nobody can start, message or answer its agents; an admin can stop a run in Console ▸ Team Workflows, on the web page. Its spend counts against its own cap and its group’s."

    public static let machineFoot = "Run this on the machine for the bot. It joins as the bot’s machine; the code works once, for 10 minutes."

    /// "$3.20", "$50".
    public static func dollars(_ usd: Double) -> String {
        usd == usd.rounded() ? "$\(Int(usd))" : String(format: "$%.2f", usd)
    }

    /// A daily cap as typed in (#2066): no cap, dollars, or the sentence that says why it is refused.
    public enum CapEntry: Equatable, Sendable {
        case none
        case dollars(Double)
        case refused(String)
    }

    public static let capNotDollars = "Type the daily cap in dollars, such as 50 or $1,000, or leave it empty for no cap."
    public static let capNotAboveZero = "A daily cap is more than $0. Leave it empty for no cap."

    /// Reads a cap typed in. Empty or "none" is no cap; "50", "$1,000", "50 USD" and "$50 a day" are dollars.
    /// Any other text is refused, never saved as no cap.
    public static func readCap(_ text: String) -> CapEntry {
        var words = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["", "none", "no cap", "no"].contains(words) { return .none }
        func strip(_ ends: [String], suffix: Bool) {
            for end in ends where suffix ? words.hasSuffix(end) : words.hasPrefix(end) {
                words = String(suffix ? words.dropLast(end.count) : words.dropFirst(end.count))
                    .trimmingCharacters(in: .whitespaces)
                return
            }
        }
        strip(["a day", "per day", "/day", "each day", "daily"], suffix: true)
        strip(["usd", "dollars", "dollar"], suffix: true)
        strip(["us$", "usd", "$"], suffix: false)
        guard let number = try? Regex(#"\d{1,3}(,\d{3})+(\.\d+)?|\d+(\.\d+)?|\.\d+"#),
              words.wholeMatch(of: number) != nil,
              let usd = Double(words.replacingOccurrences(of: ",", with: "")), usd.isFinite
        else { return .refused(capNotDollars) }
        return usd > 0 ? .dollars(usd) : .refused(capNotAboveZero)
    }
}

/// The cap notices an admin is shown (#2073): one per bot, the last told, and only while it
/// is true: before its `until`, and while the cap it names is the one the bot, or the
/// bot's group, has now. The web page's are `openCaps` in `Web/src/model/teamGroups.ts`.
public enum CapNotices {
    /// `control/capReached`: this bot's notice, in place of any it had.
    public static func adding(_ reached: DaemonAPI.CapReached, to notices: [DaemonAPI.CapReached]) -> [DaemonAPI.CapReached] {
        notices.filter { $0.user != reached.user } + [reached]
    }

    /// The notices still true at `now`. With no people list yet, only the time is weighed.
    public static func open(_ notices: [DaemonAPI.CapReached], people: [DaemonAPI.PersonRow]?, groups: [DaemonAPI.Group],
                            at now: Date = Date()) -> [DaemonAPI.CapReached] {
        notices.filter { notice in
            guard notice.until > now else { return false }
            guard let people else { return true }
            // A bot removed has no cap to change.
            guard let bot = people.first(where: { $0.id == notice.user }) else { return false }
            guard let name = notice.group else { return bot.caps?.dailyUSD == notice.capUSD }
            // Its group's cap: changed, or the bot moved to another group.
            guard let group = groups.first(where: { $0.name == name }) else { return false }
            return bot.group == group.id && group.caps?.dailyUSD == notice.capUSD
        }
    }
}
