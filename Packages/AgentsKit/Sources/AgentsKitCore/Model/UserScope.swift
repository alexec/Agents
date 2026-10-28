import Foundation

/// The user scope (#1760, spec 736 US4): a person's settings and secrets, which the control
/// plane keeps and sends to each machine of theirs when it joins and when they change. Only
/// the person's own clients change them. A secret's value is never sent back to a client.
public extension DaemonAPI {
    /// A part of the user settings. Each keeps the shape its file has on a machine.
    enum UserSettingsPartName: String, Codable, Sendable, Hashable, CaseIterable {
        case mcpServers, agentConfig, runtimes, costLimits
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
    /// the base64 file contents on host/userSettings.
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
        public var updated: String?

        public init(mcpServers: JSONValue? = nil, agentConfig: JSONValue? = nil, agentConfigFiles: AgentConfigFiles? = nil, runtimes: JSONValue? = nil,
                    costLimits: JSONValue? = nil, updated: String? = nil) {
            self.mcpServers = mcpServers
            self.agentConfig = agentConfig
            self.agentConfigFiles = agentConfigFiles
            self.runtimes = runtimes
            self.costLimits = costLimits
            self.updated = updated
        }

        public subscript(part: UserSettingsPartName) -> JSONValue? {
            switch part {
            case .mcpServers: mcpServers
            case .agentConfig: agentConfig
            case .runtimes: runtimes
            case .costLimits: costLimits
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

/// The words for settings with a fixed scope (#2410) and the Secrets page.
public enum UserScopeWords {
    /// Machines ▸ Secrets.
    public static let secretsTitle = "Secrets"
    public static let yoursOnEveryMachine = "Yours, on every machine"
    /// Under "This Mac's" at the top of the `~/.agents` pages and editors (#2704): what goes to
    /// the person's other machines. A machine does not send its `~/.agents` files (#2703); the
    /// Mac's Settings window sets these parts at the user scope (`keepFollowingParts`).
    public static let agentConfigurationFollows = "Your other machines get this Mac's instructions, personas, "
        + "skills and MCP servers from the Mac's Settings window. Workflows, plugins and a skill's other files stay on this Mac."

    public static let thisMacOnly = "This Mac's"
    public static let addSecret = "Add a Secret…"

    public static let secretsFoot = "A secret goes only to your own machines, into ~/.agents-secrets/secrets.env. "
        + "Write ${NAME} for it in an MCP server's env or headers. Nobody can read it back, you included: to change it, replace it."
    public static let noSealing = "This control plane has no key to seal secrets with, so it keeps none. "
        + "Its operator starts it with a key file or AGENTS_CONTROL_KMS."
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
