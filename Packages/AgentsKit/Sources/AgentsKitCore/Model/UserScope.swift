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
}

public extension DaemonAPI.Notification {
    /// `UserSettingsChanged` (#1760).
    static let controlUserSettingsChanged = "control/userSettingsChanged"
    /// `SecretsLeft` (#1760).
    static let controlSecretsLeft = "control/secretsLeft"
}
