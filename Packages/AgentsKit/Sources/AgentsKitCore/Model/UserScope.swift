import Foundation

/// The user scope (#1760, spec 736 US4): a person's settings and secrets, which the control
/// plane keeps and sends to each machine of theirs when it joins and when they change. Only
/// the person's own clients change them. A secret's value is never sent back to a client in
/// plain text: only a client's own sealed copy, to reveal or copy (`user/sealedSecret`, #5114).
public extension DaemonAPI {
    /// A part of the user settings. Each keeps the shape its file has on a machine.
    enum UserSettingsPartName: String, Codable, Sendable, Hashable, CaseIterable {
        case mcpServers, agentConfig, runtimes, costLimits, notifications, accounts, timeZone
    }

    /// The timeZone part (#4818): the person's time zone, which their Mac sets from its own
    /// clock. A workflow's `hours:` with no `time-zone:` go by it, on every machine.
    struct UserTimeZone: Codable, Sendable, Hashable {
        /// An IANA name, as `TimeZone.identifier` says it: `Europe/London`.
        public var identifier: String

        public init(identifier: String) { self.identifier = identifier }
    }

    /// The agentConfig part: the person's own instructions, personas and skills.
    struct UserAgentConfig: Codable, Sendable, Hashable {
        /// `~/.agents/AGENTS.md`.
        public var instructions: String?
        /// `~/.agents/personas/<name>.md`, by name.
        public var personas: [String: String]?
        /// `~/.agents/skills/<name>/SKILL.md`, by name.
        public var skills: [String: String]?

        public init(instructions: String? = nil, personas: [String: String]? = nil, skills: [String: String]? = nil) {
            self.instructions = instructions
            self.personas = personas
            self.skills = skills
        }
    }

    /// Per-file configuration state (#2129). Clients get metadata only; machines receive
    /// the base64 file contents on machine/userSettings.
    struct AgentConfigFile: Codable, Sendable, Hashable {
        public var path: String
        public var contents: String?
        public var deleted: Bool?
        public var time: Int64
        public var counter: Int64
        public var machine: String
        public var digest: String
    }

    struct AgentConfigFiles: Codable, Sendable, Hashable {
        public var files: [AgentConfigFile]
        public var updated: String?
    }

    /// `user/settings`: the person's fixed-scope settings. An omitted part has no value yet;
    /// it does not make that setting machine-local.
    struct UserSettings: Codable, Sendable, Hashable {
        public var mcpServers: JSONValue?
        public var agentConfig: JSONValue?
        public var agentConfigFiles: AgentConfigFiles?
        public var runtimes: JSONValue?
        public var costLimits: JSONValue?
        /// The person's notice limits (#2859): `{"burst", "cooldownMinutes"}`.
        public var notifications: JSONValue?
        /// The person's outside accounts (#3967), as an `OutsideAccounts`.
        public var accounts: JSONValue?
        /// The person's time zone (#4818), as a `UserTimeZone`.
        public var timeZone: JSONValue?
        public var updated: String?

        public init(mcpServers: JSONValue? = nil, agentConfig: JSONValue? = nil, agentConfigFiles: AgentConfigFiles? = nil, runtimes: JSONValue? = nil,
                    costLimits: JSONValue? = nil, notifications: JSONValue? = nil, accounts: JSONValue? = nil, timeZone: JSONValue? = nil,
                    updated: String? = nil) {
            self.timeZone = timeZone
            self.mcpServers = mcpServers
            self.agentConfig = agentConfig
            self.agentConfigFiles = agentConfigFiles
            self.runtimes = runtimes
            self.costLimits = costLimits
            self.notifications = notifications
            self.accounts = accounts
            self.updated = updated
        }

        public subscript(part: UserSettingsPartName) -> JSONValue? {
            switch part {
            case .mcpServers: mcpServers
            case .agentConfig: agentConfig
            case .runtimes: runtimes
            case .costLimits: costLimits
            case .notifications: notifications
            case .accounts: accounts
            case .timeZone: timeZone
            }
        }
    }

    /// Settings ▸ You ▸ Accounts (#3967): one outside account of the person's. It holds no secret:
    /// `card` and `secret` are the names of secrets in Settings ▸ You ▸ Secrets, or where one is.
    struct OutsideAccount: Codable, Sendable, Hashable, Identifiable {
        public var service: String
        /// What it is for and who uses it (#4164), so an agent can tell it from the other
        /// accounts of the same service. nil on an account made before it.
        public var description: String?
        public var address: String?
        public var plan: String?
        public var monthlyCostUsd: Double?
        public var card: String?
        public var secret: String?
        public var twoFactor: String?
        public var issue: String?
        public var made: String?
        /// When it was last changed (#4157), by an agent's add or an Edit…; nil for one never changed.
        public var edited: Date?
        /// Its newest operation (#4157), as user/settings gives it (#4160); the control plane drops it on a set.
        public var lastOp: AccountLastOp?
        public var tokenExpires: String?
        public var notes: String?
        /// The projects that use it, by name; none is all of them.
        public var projects: [String]?
        /// Ask before use (#4163): an agent's read of it waits on a person. nil is on; false is off.
        public var askBeforeUse: Bool?

        public var id: String { service.lowercased() + "#" + (address ?? "").lowercased() }

        public init(service: String, description: String? = nil, address: String? = nil, plan: String? = nil, monthlyCostUsd: Double? = nil,
                    card: String? = nil, secret: String? = nil, twoFactor: String? = nil, issue: String? = nil,
                    made: String? = nil, tokenExpires: String? = nil, notes: String? = nil, projects: [String]? = nil,
                    askBeforeUse: Bool? = nil, edited: Date? = nil, lastOp: AccountLastOp? = nil) {
            self.service = service
            self.edited = edited
            self.lastOp = lastOp
            self.description = description
            self.address = address
            self.plan = plan
            self.monthlyCostUsd = monthlyCostUsd
            self.card = card
            self.secret = secret
            self.twoFactor = twoFactor
            self.issue = issue
            self.made = made
            self.tokenExpires = tokenExpires
            self.notes = notes
            self.projects = projects
            self.askBeforeUse = askBeforeUse
        }
    }

    /// An account's newest operation (#4157): `read`, `added` or `edited`, when, and the session that did it.
    struct AccountLastOp: Codable, Sendable, Hashable {
        public var what: String
        public var at: Date
        /// The session that did it; nil when no session did.
        public var agent: UUID?

        public init(what: String, at: Date, agent: UUID? = nil) {
            self.what = what
            self.at = at
            self.agent = agent
        }
    }

    /// The accounts part.
    struct OutsideAccounts: Codable, Sendable, Hashable {
        public var accounts: [OutsideAccount]

        public init(accounts: [OutsideAccount]) { self.accounts = accounts }
    }

    /// `user/setSettings`: one part, or `.null` to take it out of the user scope.
    struct UserSettingsPart: Codable, Sendable, Hashable {
        public var part: UserSettingsPartName
        public var value: JSONValue

        public init(part: UserSettingsPartName, value: JSONValue) {
            self.part = part
            self.value = value
        }
    }

    /// `user/setSecret` (#3397): a secret as the person's client sealed it to each recipient of
    /// `user/secretRecipients`, by recipient. The name is capital letters, digits and `_`, as
    /// `${NAME}` in mcp.json. The control plane never has the value.
    struct UserSecretSet: Codable, Sendable, Hashable {
        public var name: String
        public var version: Int
        public var values: [String: Envelope]
        /// `card` for a card secret (#3531); nil for a plain value.
        public var kind: String?
        /// Ask before use (#4014): every envelope's associated data ends `|ask`. nil is off.
        public var needsApproval: Bool?
        /// What it is for (#4167): not secret, and not sealed. nil has none.
        public var description: String?

        public init(name: String, version: Int, values: [String: Envelope], kind: String? = nil, needsApproval: Bool? = nil,
                    description: String? = nil) {
            self.name = name
            self.version = version
            self.values = values
            self.kind = kind
            self.needsApproval = needsApproval
            self.description = description
        }
    }

    /// `user/removeSecret`.
    struct UserSecretRequest: Codable, Sendable, Hashable {
        public var name: String

        public init(name: String) { self.name = name }
    }

    /// `user/sealedSecret` (#5112, #5114): this client's own sealed copy of one of the person's
    /// secrets, to reveal or copy it. The control plane audits it with the name, never the value.
    struct UserSealedSecretRequest: Codable, Sendable, Hashable {
        public enum Purpose: String, Codable, Sendable, Hashable { case reveal, copy }
        /// A card's part, for a copy of that one part (#3531).
        public enum Part: String, Codable, Sendable, Hashable { case number, expiry, cvc, name, zip }
        /// The account it was opened from, for the audit entry.
        public struct Account: Codable, Sendable, Hashable {
            public var service: String
            public var address: String?

            public init(service: String, address: String? = nil) {
                self.service = service
                self.address = address
            }
        }

        public var name: String
        public var purpose: Purpose
        public var part: Part?
        public var account: Account?

        public init(name: String, purpose: Purpose, part: Part? = nil, account: Account? = nil) {
            self.name = name
            self.purpose = purpose
            self.part = part
            self.account = account
        }
    }

    /// `user/sealedSecret`'s answer: this client's envelope (`c:<CLIENT UUID>`), associated
    /// data `usersecret.v1|<person>|c:<CLIENT UUID>|<name>|<version>`, `|ask` when
    /// `needsApproval`.
    struct UserSealedSecret: Codable, Sendable, Hashable {
        public var name: String
        public var version: Int
        public var kind: String?
        public var needsApproval: Bool?
        public var sealed: Envelope

        public init(name: String, version: Int, sealed: Envelope, kind: String? = nil, needsApproval: Bool? = nil) {
            self.name = name
            self.version = version
            self.sealed = sealed
            self.kind = kind
            self.needsApproval = needsApproval
        }
    }

    /// A machine removed with a secret on it (FR-026).
    struct SecretLeftOn: Codable, Sendable, Hashable {
        public var host: String
        public var name: String
        public var at: String
    }

    /// A secret's last operation (#4158): what it was, when, and the session that did it. No place, no value.
    struct SecretLastOp: Codable, Sendable, Hashable {
        /// `read`, `denied`, `added`, `replaced` or `removed`.
        public var what: String
        public var at: Date
        /// The session that did it; nil for a change no session made.
        public var agent: UUID?

        public init(what: String, at: Date, agent: UUID? = nil) {
            self.what = what
            self.at = at
            self.agent = agent
        }
    }

    /// One row of `user/secretNames`: never a value.
    struct UserSecretRow: Codable, Sendable, Hashable, Identifiable {
        public var name: String
        public var updated: String
        public var machines: [String]
        public var leftOn: [SecretLeftOn]?
        public var version: Int?
        /// The person's machines that have no copy yet (#3397).
        public var waiting: [String]?
        /// `card` for a card secret (#3531); nil for a plain value.
        public var kind: String? = nil
        /// Ask before use (#4014), as the person's client last sealed it.
        public var needsApproval: Bool? = nil
        /// What it is for (#4167), in clear beside the name.
        public var description: String? = nil
        /// When the name was first set (#4158); Replace… keeps it. Nil for one set before it was kept.
        public var created: String? = nil
        /// The value's last 4 (#4158), from a machine that holds a copy; nil for a short value.
        public var hint: String? = nil
        /// Its newest operation on any machine (#4158).
        public var lastOp: SecretLastOp? = nil
        /// False when one copy only opens (#4158).
        public var backedUp: Bool? = nil

        public var id: String { name }
        public var isCard: Bool { kind == CardSecret.kind }
        public var asksBeforeUse: Bool { needsApproval == true }
    }

    /// `user/secretNames`.
    struct UserSecretNames: Codable, Sendable, Hashable {
        public var secrets: [UserSecretRow]
    }

    /// `control/userSettingsChanged`: read the user scope again.
    struct UserSettingsChanged: Codable, Sendable, Hashable {
        public var parts: [UserSettingsPartName]?
        public var agentConfigFiles: Bool?
        public var secrets: Bool?
    }

    /// `settings/userPart`, to a machine: one part as it has it, for Use This Mac's.
    struct UserPartRequest: Codable, Sendable, Hashable {
        public var part: UserSettingsPartName

        public init(part: UserSettingsPartName) { self.part = part }
    }

    /// `settings/userPart`'s answer. `leftOut` names what could not be taken: a skill with
    /// files beside its SKILL.md.
    struct UserPartHere: Codable, Sendable, Hashable {
        public var part: UserSettingsPartName
        public var value: JSONValue
        public var leftOut: [String]?
    }

    /// `control/secretsLeft`: a machine of the person's was removed with these secrets on it.
    struct SecretsLeft: Codable, Sendable, Hashable {
        public var host: String
        public var name: String
        public var secrets: [String]
    }
}

public extension DaemonAPI.Method {
    /// `{}` → `UserSettings` (#1760).
    static let userSettings = "user/settings"
    /// `UserSettingsPart` → `{}` (#1760).
    static let userSetSettings = "user/setSettings"
    /// `AgentConfigFileRequest` → `{}` (#2129).
    static let userSetAgentConfigFile = "user/setAgentConfigFile"
    /// `UserSecretSet` → `{}` (#1760, #3397).
    static let userSetSecret = "user/setSecret"
    /// `{}` → `SealRecipients`: the person's machines and clients, to seal a secret to (#3397).
    static let userSecretRecipients = "user/secretRecipients"
    /// `UserSealedSecretRequest` → `UserSealedSecret`: this client's own copy, audited (#5114).
    static let userSealedSecret = "user/sealedSecret"
    /// `UserSecretRequest` → `{}` (#1760).
    static let userRemoveSecret = "user/removeSecret"
    /// `{}` → `UserSecretNames` (#1760).
    static let userSecretNames = "user/secretNames"
    /// To a machine: `UserPartRequest` → `UserPartHere` (#1760).
    static let settingsUserPart = "settings/userPart"
}

public extension DaemonAPI.Notification {
    /// `UserSettingsChanged` (#1760).
    static let controlUserSettingsChanged = "control/userSettingsChanged"
    /// `SecretsLeft` (#1760).
    static let controlSecretsLeft = "control/secretsLeft"
}

/// The words for settings with a fixed scope (#2410) and the Secrets page.
public enum UserScopeWords {
    /// Settings ▸ You ▸ Secrets (#3632).
    public static let secretsTitle = "Secrets"
    public static let yoursOnEveryMachine = "Yours, on every machine"
    /// Under "This Mac's" at the top of the `~/.agents` pages and editors (#2704): what goes to
    /// the person's other machines. A machine does not send its `~/.agents` files (#2703); the
    /// Mac's Settings window sets these parts at the user scope (`keepFollowingParts`).
    public static let agentConfigurationFollows = "Your other machines get this Mac's instructions, personas, "
        + "skills and MCP servers from the Mac's Settings window. Workflows, plugins and a skill's other files stay on this Mac."

    public static let thisMacOnly = "This Mac's"
    public static let addSecret = "Add a Secret…"

    public static let secretsFoot = "A secret is sealed in this app to each of your own machines and apps; the control plane "
        + "cannot open it. Write ${NAME} for it in an MCP server's env or headers. You can reveal and copy it here, and each "
        + "reveal and copy is in the audit log. Agents never get a value from here. To change it, replace it."

    // Reveal and Copy (#5112, #5115; specs/5112-view-copy-secrets-accounts/wireframes.md).
    public static let reveal = "Reveal"
    public static let hide = "Hide"
    public static let copy = "Copy"
    public static let copyValue = "Copy Value"
    /// How long a value shows, and how long until the clipboard is cleared of it.
    public static let shownSeconds = 30
    public static let clipboardSeconds = 90
    /// How long Copy shows its check, and the copied line.
    public static let copiedSeconds = 2

    /// Under a shown value, with the seconds left.
    public static func hidesIn(_ seconds: Int, card: Bool) -> String {
        "Hides in \(max(seconds, 0)) s · " + (card ? "each reveal and copy is in the audit log" : "in the audit log")
    }

    /// Under a row just copied: the whole value, or one part of a card.
    public static func copied(_ part: DaemonAPI.UserSealedSecretRequest.Part? = nil) -> String {
        (part.map { "Copied \(partWords($0))." } ?? "Copied.") + " The clipboard clears in \(clipboardSeconds) s."
    }

    /// Ask before use, on a row a person can reveal: it holds only an agent's use (#4016).
    public static let asksForAgents = "Asks before use: for agents. You reveal and copy at once."
    public static let noCopyYet = "This app has no copy yet. It gets one when another app of yours is online."
    public static let revealNeedsNewerPlane = "This control plane cannot show or copy a secret yet. Update it."
    public static let didNotOpen = "This app's copy did not open. Replace the secret to seal it again."

    /// A card's part, as its line names it.
    public static func partLabel(_ part: DaemonAPI.UserSealedSecretRequest.Part) -> String {
        switch part {
        case .number: "Card number"
        case .expiry: "Expiry"
        case .cvc: "CVC"
        case .name: "Name on card"
        case .zip: "Billing ZIP"
        }
    }

    /// A card's part in a sentence, as the audit entry names it.
    public static func partWords(_ part: DaemonAPI.UserSealedSecretRequest.Part) -> String {
        switch part {
        case .number: "the card number"
        case .expiry: "the expiry"
        case .cvc: "the CVC"
        case .name: "the name on card"
        case .zip: "the billing ZIP"
        }
    }

    /// A card's parts, in the order a reveal shows them.
    public static let cardParts: [DaemonAPI.UserSealedSecretRequest.Part] = [.number, .expiry, .cvc, .name, .zip]

    /// Under a secret that one of the person's machines has no copy of yet (#3397).
    public static func waiting(_ row: DaemonAPI.UserSecretRow) -> String? {
        let n = row.waiting?.count ?? 0
        guard n > 0 else { return nil }
        return "\(n == 1 ? "1 machine waits" : "\(n) machines wait") for one of your apps to seal it there. This happens when you open Agents."
    }

    /// The version a secret is set at (#3397): the kept one plus one; for a new name, the time
    /// in milliseconds, above a removed one's, which the client cannot see.
    public static func nextVersion(_ row: DaemonAPI.UserSecretRow?, now: Date) -> Int {
        if let version = row?.version { return version + 1 }
        return Int(now.timeIntervalSince1970 * 1000)
    }
    /// A secret's row: where it is.
    public static func machines(_ row: DaemonAPI.UserSecretRow) -> String {
        switch row.machines.count {
        case 0: "On no machine yet"
        case 1: "On 1 machine"
        default: "On \(row.machines.count) machines"
        }
    }

    /// Under a secret that was on a machine since removed (FR-026).
    public static func leftOn(_ row: DaemonAPI.UserSecretRow) -> String? {
        guard let left = row.leftOn, !left.isEmpty else { return nil }
        let names = left.map(\.name).joined(separator: ", ")
        return "It was on \(names), which was removed. Change it where it was issued, then replace it here."
    }

    /// When a machine of yours went with secrets on it (control/secretsLeft).
    public static func secretsLeft(_ left: DaemonAPI.SecretsLeft) -> String {
        let names = left.secrets.joined(separator: ", ")
        return "\(left.name) was removed with \(left.secrets.count == 1 ? "this secret" : "these secrets") on it: \(names). "
            + "Change \(left.secrets.count == 1 ? "it" : "them") where \(left.secrets.count == 1 ? "it was" : "they were") issued."
    }

    /// A secret's name as the person types it: capital letters, digits and _.
    public static func isSecretName(_ name: String) -> Bool {
        name.range(of: #"^[A-Z_][A-Z0-9_]{0,63}$"#, options: .regularExpression) != nil
    }

    public static let nameHint = "Capital letters, digits and _, such as GITHUB_TOKEN."

    // A secret's description (#4167): not secret, and kept beside the name.
    public static let descriptionLabel = "Description"
    public static let descriptionPrompt = "What it is for: which account, which scopes, whose"
    public static let descriptionHint = "Agents read the description to choose the right secret. It is not sealed: never put a value in it."
    public static let noDescription = "No description"

    /// The description under a secret's name, or No description.
    public static func about(_ description: String?) -> String {
        let text = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? noDescription : text
    }

    /// What a sheet sends for its description field: nil when it is empty.
    public static func description(_ typed: String) -> String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // Card secrets (#3531).
    public static let addCard = "Add a Card…"
    public static let cardKind = "Card"
    /// Where a person adds a card: what a card for agents must be.
    public static let cardRule = "Add only a card that has a spend limit, such as a Privacy.com card. A card locked to one merchant or category is safer. "
        + "An agent fills it into a page with fill_secret and never sees it. It stays sealed on your own machines."
    public static let cardConfirm = "This card has a spend limit"

    public static func refusal(_ error: any Error) -> String {
        if let error = error as? JSONRPCError {
            return error.code == JSONRPCError.methodNotFound
                ? "This control plane does not keep settings for you yet. Update it."
                : error.message
        }
        return "The control plane can’t be reached."
    }
}

/// A card secret (#3531, #3923): a payment card that has a spend limit (a merchant or category lock
/// is recommended), kept as one secret whose value is a JSON object of its parts. agentsd's fill_secret reads it
/// a part at a time (`Go/internal/agentsd/browserfill.go`); the web page writes the same in
/// `Web/src/model/userScope.ts`.
public struct CardSecret: Codable, Sendable, Hashable {
    public static let kind = "card"

    public var number: String
    /// MM/YY.
    public var expiry: String
    public var cvc: String
    public var name: String
    public var zip: String

    /// The card as the person typed it, tidied: the number's digits only, the expiry as MM/YY.
    public init(number: String, expiry: String, cvc: String, name: String, zip: String) {
        self.number = number.filter(Self.isDigit)
        self.expiry = Self.tidyExpiry(expiry)
        self.cvc = cvc.trimmingCharacters(in: .whitespaces)
        self.name = name.trimmingCharacters(in: .whitespaces)
        self.zip = zip.trimmingCharacters(in: .whitespaces)
    }

    /// What is wrong with it, or nil when it can be added.
    public var problem: String? {
        if !(12...19).contains(number.count) || !Self.luhn(number) { return "The card number is not right." }
        guard let month = Int(expiry.prefix(2)), (1...12).contains(month),
              expiry.range(of: #"^\d{2}/\d{2}$"#, options: .regularExpression) != nil
        else { return "Write the expiry as MM/YY." }
        if cvc.range(of: #"^\d{3,4}$"#, options: .regularExpression) == nil { return "The CVC is 3 or 4 digits." }
        if name.isEmpty { return "Write the name on the card." }
        if zip.isEmpty || zip.count > 10 { return "Write the billing ZIP or postal code." }
        return nil
    }

    /// The secret's value: one line of JSON, so it fits one record of the sealed store.
    public var value: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// A card's value as it was sealed (#5115), or nil when it is not a card's.
    public init?(value: String) {
        guard let card = try? JSONDecoder().decode(CardSecret.self, from: Data(value.utf8)) else { return nil }
        self = card
    }

    /// One part (#5115), for a reveal's line and its Copy.
    public func part(_ part: DaemonAPI.UserSealedSecretRequest.Part) -> String {
        switch part {
        case .number: number
        case .expiry: expiry
        case .cvc: cvc
        case .name: name
        case .zip: zip
        }
    }

    /// The card number in groups of four, as a reveal shows it.
    public var spacedNumber: String {
        stride(from: 0, to: number.count, by: 4).map { i in
            let start = number.index(number.startIndex, offsetBy: i)
            return String(number[start..<(number.index(start, offsetBy: 4, limitedBy: number.endIndex) ?? number.endIndex)])
        }.joined(separator: " ")
    }

    static func tidyExpiry(_ typed: String) -> String {
        let parts = typed.split(whereSeparator: { !Self.isDigit($0) }).map(String.init)
        if parts.count == 2 {
            let month = parts[0].count == 1 ? "0" + parts[0] : parts[0]
            let year = parts[1].count == 4 ? String(parts[1].suffix(2)) : parts[1]
            return month + "/" + year
        }
        let digits = typed.filter(Self.isDigit)
        return digits.count == 4 ? String(digits.prefix(2)) + "/" + String(digits.suffix(2)) : typed.trimmingCharacters(in: .whitespaces)
    }

    static func isDigit(_ c: Character) -> Bool { ("0"..."9").contains(c) }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, c) in digits.reversed().enumerated() {
            guard var d = c.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }
}
