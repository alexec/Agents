import Foundation

/// The user scope (#1760, spec 736 US4): a person's settings and secrets, which the control
/// plane keeps and sends to each machine of theirs when it joins and when they change. Only
/// the person's own clients change them. A secret's value is never sent back to a client.
public extension DaemonAPI {
    /// A part of the user settings. Each keeps the shape its file has on a machine.
    enum UserSettingsPartName: String, Codable, Sendable, Hashable, CaseIterable {
        case mcpServers, agentConfig, runtimes, costLimits, notifications, accounts
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
        public var updated: String?

        public init(mcpServers: JSONValue? = nil, agentConfig: JSONValue? = nil, agentConfigFiles: AgentConfigFiles? = nil, runtimes: JSONValue? = nil,
                    costLimits: JSONValue? = nil, notifications: JSONValue? = nil, accounts: JSONValue? = nil, updated: String? = nil) {
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
            }
        }
    }

    /// Your setup ▸ Accounts (#3967): one outside account of the person's. It holds no secret:
    /// `card` and `secret` are the names of secrets in Your setup ▸ Secrets, or where one is.
    struct OutsideAccount: Codable, Sendable, Hashable, Identifiable {
        public var service: String
        public var address: String?
        public var plan: String?
        public var monthlyCostUsd: Double?
        public var card: String?
        public var secret: String?
        public var twoFactor: String?
        public var issue: String?
        public var made: String?
        public var tokenExpires: String?
        public var notes: String?
        /// The projects that use it, by name; none is all of them.
        public var projects: [String]?

        public var id: String { service.lowercased() + "#" + (address ?? "").lowercased() }

        public init(service: String, address: String? = nil, plan: String? = nil, monthlyCostUsd: Double? = nil,
                    card: String? = nil, secret: String? = nil, twoFactor: String? = nil, issue: String? = nil,
                    made: String? = nil, tokenExpires: String? = nil, notes: String? = nil, projects: [String]? = nil) {
            self.service = service
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

        public init(name: String, version: Int, values: [String: Envelope], kind: String? = nil, needsApproval: Bool? = nil) {
            self.name = name
            self.version = version
            self.values = values
            self.kind = kind
            self.needsApproval = needsApproval
        }
    }

    /// `user/removeSecret`.
    struct UserSecretRequest: Codable, Sendable, Hashable {
        public var name: String

        public init(name: String) { self.name = name }
    }

    /// A machine removed with a secret on it (FR-026).
    struct SecretLeftOn: Codable, Sendable, Hashable {
        public var host: String
        public var name: String
        public var at: String
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
    /// Your setup ▸ Secrets (#3632).
    public static let secretsTitle = "Secrets"
    public static let yoursOnEveryMachine = "Yours, on every machine"
    /// Under "This Mac's" at the top of the `~/.agents` pages and editors (#2704): what goes to
    /// the person's other machines. A machine does not send its `~/.agents` files (#2703); the
    /// Mac's Settings window sets these parts at the user scope (`keepFollowingParts`).
    public static let agentConfigurationFollows = "Your other machines get this Mac's instructions, personas, "
        + "skills and MCP servers from the Mac's Settings window. Workflows, plugins and a skill's other files stay on this Mac."

    public static let thisMacOnly = "This Mac's"
    public static let addSecret = "Add a Secret…"

    public static let secretsFoot = "A secret is sealed in this app to each of your own machines, and goes into ~/.agents-secrets/secrets.env "
        + "there; the control plane cannot open it. Write ${NAME} for it in an MCP server's env or headers. Nobody can read it back, "
        + "you included: to change it, replace it."

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

    /// The secret's value: one line of JSON, so it fits a NAME=value line of secrets.env.
    public var value: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
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
