import Foundation

/// Whether a runtime can be used, how to sign into it, and who is answering.
///
/// A runtime fact, not an agent one: every agent using Copilot is signed in as the same
/// person, so this is held once per runtime and refreshed on every handshake.
public struct RuntimeAccount: Codable, Hashable, Sendable, Identifiable {
    public var runtimeID: String
    public var state: State
    public var authMethods: [ACP.AuthMethod]
    public var canLogOut: Bool
    public var providers: [ACP.ProviderInfo]
    public var currentProviderID: String?
    public var checkedAt: Date

    public var id: String { runtimeID }

    public enum State: String, Codable, Hashable, Sendable {
        case ready
        case needsSignIn
        /// Never handshaken with, so nothing is known. Not the same as not signed in.
        case unknown
    }

    public init(runtimeID: String,
                state: State = .unknown,
                authMethods: [ACP.AuthMethod] = [],
                canLogOut: Bool = false,
                providers: [ACP.ProviderInfo] = [],
                currentProviderID: String? = nil,
                checkedAt: Date = Date()) {
        self.runtimeID = runtimeID
        self.state = state
        self.authMethods = authMethods
        self.canLogOut = canLogOut
        self.providers = providers
        self.currentProviderID = currentProviderID
        self.checkedAt = checkedAt
    }

    /// What a handshake told us. Signing in is not proved by having auth methods:
    /// Copilot advertises `copilot-login` while perfectly signed in, which is why the
    /// state only changes to `needsSignIn` when a call actually refuses.
    public init(runtimeID: String, handshake: ACP.InitializeResult) {
        self.init(runtimeID: runtimeID,
                  state: .ready,
                  authMethods: handshake.authMethods ?? [],
                  canLogOut: handshake.supportsLogout,
                  providers: [],
                  currentProviderID: nil)
    }

    /// The method to offer first: the one that can be done without a terminal.
    public var preferredMethod: ACP.AuthMethod? {
        authMethods.first { $0.terminalCommand == nil } ?? authMethods.first
    }

    public var needsTerminal: Bool {
        preferredMethod?.terminalCommand != nil
    }
}

extension ACP.AuthMethod: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: AuthKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(_meta, forKey: ._meta)
    }

    enum AuthKeys: String, CodingKey {
        case id, name, description, _meta
    }
}

extension ACP.ProviderInfo: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: ProviderKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(`protocol`, forKey: .protocol)
        try c.encodeIfPresent(configured, forKey: .configured)
    }

    enum ProviderKeys: String, CodingKey {
        case id, name, `protocol`, configured
    }
}
