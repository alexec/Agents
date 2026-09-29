import Foundation

/// What the person asks of a runtime's command sandbox (064): a runtime's default, or one
/// agent's override. `runtime` adds nothing to the launch, so the runtime's own settings
/// decide, exactly as before this feature.
public enum SandboxChoice: String, Codable, Sendable, Hashable, CaseIterable {
    case runtime
    case on
    case off

    /// A value this build does not know reads as `runtime`: never wider than asked.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SandboxChoice(rawValue: raw) ?? .runtime
    }
}

/// The isolation an agent's commands actually run under, as far as the app can vouch.
public enum SandboxState: String, Codable, Sendable, Hashable {
    case on
    case off
    /// The runtime's own settings decide, and the app cannot read them.
    case runtimeControlled
    /// The runtime has no command sandbox the app's agents get (Antigravity, OpenCode).
    case none

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SandboxState(rawValue: raw) ?? .runtimeControlled
    }
}

/// One agent's sandbox at its latest start (FR-010): what was asked, what is in force, and
/// why the two differ when they do.
public struct EffectiveSandbox: Codable, Sendable, Hashable {
    public var state: SandboxState
    public var requested: SandboxChoice
    /// Such as "Limited by the agent that started it".
    public var reason: String?

    public init(state: SandboxState, requested: SandboxChoice, reason: String? = nil) {
        self.state = state
        self.requested = requested
        self.reason = reason
    }
}

/// `<root>/sandbox-settings.json`: one default per runtime. A runtime not in it is
/// `runtime` (FR-003c), so a missing or unreadable file changes nothing.
public struct SandboxSettings: Codable, Sendable, Hashable {
    public var defaults: [String: SandboxChoice]

    public init(defaults: [String: SandboxChoice] = [:]) {
        self.defaults = defaults
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaults = try c.decodeIfPresent([String: SandboxChoice].self, forKey: .defaults) ?? [:]
    }

    private enum CodingKeys: String, CodingKey { case defaults }

    public func choice(for runtimeID: String) -> SandboxChoice {
        defaults[runtimeID] ?? .runtime
    }

    /// The same settings with one runtime's default changed. `runtime` is stored as absent.
    public func setting(_ choice: SandboxChoice, for runtimeID: String) -> SandboxSettings {
        var settings = self
        settings.defaults[runtimeID] = choice == .runtime ? nil : choice
        return settings
    }
}

/// A runtime's sandbox that could not be set up (064, FR-006, FR-007): the card in the
/// conversation, and, once the person has answered it, the note it becomes.
public struct SandboxFailureRecord: Codable, Sendable, Hashable {
    public enum Resolution: String, Codable, Sendable, Hashable {
        case pending, keptStopped, continued

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Resolution(rawValue: raw) ?? .keptStopped
        }
    }

    public var runtimeID: String
    /// The runtime's own words that were recognised, trimmed, for "Show details".
    public var detail: String
    /// Gemini never answered: the text is the app's, not the runtime's (R6).
    public var hang: Bool
    /// Whether **Continue without sandbox** is offered: the runtime has an Off route.
    public var recoveryOffered: Bool
    /// Tool calls that finished in the failed turn. Nonzero means recovery asks the agent
    /// to carry on rather than sending the prompt again (R12).
    public var completedToolCalls: Int
    public var resolution: Resolution

    public init(runtimeID: String, detail: String, hang: Bool = false, recoveryOffered: Bool,
                completedToolCalls: Int = 0, resolution: Resolution = .pending) {
        self.runtimeID = runtimeID
        self.detail = detail
        self.hang = hang
        self.recoveryOffered = recoveryOffered
        self.completedToolCalls = completedToolCalls
        self.resolution = resolution
    }
}
