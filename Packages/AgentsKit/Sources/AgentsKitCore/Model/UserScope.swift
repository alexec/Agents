import Foundation

/// The user scope (#1760, spec 736 US4): a person's settings and secrets, which the control
/// plane keeps and sends to each machine of theirs when it joins and when they change. Only
/// the person's own clients change them. A secret's value is never sent back to a client.
public extension DaemonAPI {
    /// A part of the user settings. Each keeps the shape its file has on a machine.
    enum UserSettingsPartName: String, Codable, Sendable, Hashable, CaseIterable {
        case mcpServers, agentConfig, runtimes, costLimits, resources
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

    /// `user/settings`: a part that is absent is not set at the user scope, and each machine
    /// keeps its own.
    struct UserSettings: Codable, Sendable, Hashable {
        public var mcpServers: JSONValue?
        public var agentConfig: JSONValue?
        public var runtimes: JSONValue?
        public var costLimits: JSONValue?
        public var resources: JSONValue?
        public var updated: String?

        public init(mcpServers: JSONValue? = nil, agentConfig: JSONValue? = nil, runtimes: JSONValue? = nil,
                    costLimits: JSONValue? = nil, resources: JSONValue? = nil, updated: String? = nil) {
            self.mcpServers = mcpServers
            self.agentConfig = agentConfig
            self.runtimes = runtimes
            self.costLimits = costLimits
            self.resources = resources
            self.updated = updated
        }

        public subscript(part: UserSettingsPartName) -> JSONValue? {
            switch part {
            case .mcpServers: mcpServers
            case .agentConfig: agentConfig
            case .runtimes: runtimes
            case .costLimits: costLimits
            case .resources: resources
            }
        }
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

    /// `user/setSecret`. The name is capital letters, digits and `_`, as `${NAME}` in mcp.json.
    struct UserSecret: Codable, Sendable, Hashable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
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

        public var id: String { name }
    }

    /// `user/secretNames`. `sealing` is false on a control plane with no key for secrets.
    struct UserSecretNames: Codable, Sendable, Hashable {
        public var secrets: [UserSecretRow]
        public var sealing: Bool
    }

    /// `control/userSettingsChanged`: read the user scope again.
    struct UserSettingsChanged: Codable, Sendable, Hashable {
        public var parts: [UserSettingsPartName]?
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
    /// `UserSecret` → `{}` (#1760).
    static let userSetSecret = "user/setSecret"
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

/// The words of the user scope (#1760, #2157): the scope line at the top of each Mac pane
/// whose part can be the same on every machine, Machines ▸ Secrets, and the parts at the end
/// of Machines on the Remote. The web page says the same in `Web/src/model/userScope.ts`.
public enum UserScopeWords {
    /// Machines ▸ Secrets.
    public static let secretsTitle = "Secrets"
    /// The parts at the end of Machines on the Remote and the web page, and each pane's switch.
    public static let partsHeading = "The same on all your machines"

    public static func partTitle(_ part: DaemonAPI.UserSettingsPartName) -> String {
        switch part {
        case .mcpServers: "MCP servers"
        case .agentConfig: "Agent configuration"
        case .runtimes: "Agent runtime choices"
        case .costLimits: "Cost limits"
        case .resources: "Resources"
        }
    }

    /// What each part holds, under its title.
    public static func partDetail(_ part: DaemonAPI.UserSettingsPartName) -> String {
        switch part {
        case .mcpServers: "Your own servers in ~/.agents/mcp.json."
        case .agentConfig: "Your instructions, personas and one-file skills in ~/.agents."
        case .runtimes: "Each runtime's sandbox and permission choices. Sign-ins stay on each machine."
        case .costLimits: "The most an agent and a day may spend."
        case .resources: "What agents take turns with, such as build."
        }
    }

    public static func partState(_ value: JSONValue?, updated: String?) -> String {
        value == nil ? "Each machine its own" : allMachines
    }

    /// The scope line over a Mac pane (#2157): where an edit in it goes.
    public static let allMachines = "All your machines"
    public static let thisMacOnly = "This Mac only"
    public static func scopeNote(_ part: DaemonAPI.UserSettingsPartName, follows: Bool) -> String {
        follows
            ? "\(partTitle(part)): a change here goes to every machine of yours, and to each new one."
            : "\(partTitle(part)): turn it on to give every machine of yours what this Mac has."
    }

    /// Asked before a part is turned on (#2390): on replaces every other machine's copy, and
    /// off does not bring it back. `machines` are the person's other machines, when known.
    public static let take = "Replace on Every Machine"
    public static func takeTitle(_ part: DaemonAPI.UserSettingsPartName) -> String {
        "\(partTitle(part)): the same on all your machines?"
    }
    public static func takeMessage(_ part: DaemonAPI.UserSettingsPartName, machines: [String]) -> String {
        let what = partInLine(part)
        let where_ = machines.isEmpty ? "every other machine of yours" : joined(machines)
        return "Replaces the \(what) on \(where_) with this Mac’s, and gives each new machine of yours this Mac’s too. "
            + "Turning this off later does not bring the old ones back."
    }

    /// A part's title inside a sentence.
    static func partInLine(_ part: DaemonAPI.UserSettingsPartName) -> String {
        part == .mcpServers ? partTitle(part) : partTitle(part).lowercased()
    }

    /// "A", "A and B", "A, B and C".
    static func joined(_ names: [String]) -> String {
        guard let last = names.last, names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    public static let stop = "Each Machine Its Own"
    public static func stopTitle(_ part: DaemonAPI.UserSettingsPartName) -> String { "\(partTitle(part)): each machine its own?" }
    public static let stopMessage = "Each machine keeps what it has now, and changes it in its own pane."
    public static let addSecret = "Add a Secret…"

    public static let secretsFoot = "A secret goes only to your own machines, into ~/.agents-secrets/secrets.env. "
        + "Write ${NAME} for it in an MCP server's env or headers. Nobody can read it back, you included: to change it, replace it."
    public static let noSealing = "This control plane has no key to seal secrets with, so it keeps none. "
        + "Its operator starts it with a key file or AGENTS_CONTROL_KMS."
    /// Under the parts on the Remote and the web page, which cannot read a machine's files.
    public static let partsFoot = "Turn one on in its own pane on the Mac. A change there then goes to every machine of yours, "
        + "and to each new one."

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

    public static func refusal(_ error: any Error) -> String {
        if let error = error as? JSONRPCError {
            return error.code == JSONRPCError.methodNotFound
                ? "This control plane does not keep settings for you yet. Update it."
                : error.message
        }
        return "The control plane can’t be reached."
    }
}
