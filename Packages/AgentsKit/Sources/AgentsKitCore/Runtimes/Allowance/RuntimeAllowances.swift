import Foundation

/// Every runtime's state, pool or none (065, US4): a row for each runtime the app finds,
/// and one for each other credential it has a state for. What Settings ▸ Agent Runtimes
/// and the phone draw, and what the prompt bar reads to warn. Never what decides whether
/// a prompt is sent.
public struct RuntimeAllowances: Codable, Hashable, Sendable {
    public var rows: [Row]
    public var at: Date
    /// The shared allowances (a plan's sign-in) as this daemon has recorded them: what
    /// the Mac's window carries between it and its servers (052, R6). Not the rows,
    /// which show a runtime nothing has happened to as available. Nil from a daemon
    /// that does not say.
    public var shared: [AllowanceState]?

    public init(rows: [Row], at: Date, shared: [AllowanceState]? = nil) {
        self.rows = rows
        self.at = at
        self.shared = shared
    }

    public var anyOut: Bool { rows.contains { $0.state.isOut } }

    /// The prompt bar's warning for a new chat on an out runtime, or nil. It names no
    /// other runtime: there is no order to take one from (065).
    public func startingOnOut(_ runtimeID: String) -> String? {
        guard let row = rows.first(where: { $0.runtimeID == runtimeID && $0.state.isOut }) else { return nil }
        return PoolWords.startingOnOut(runtimeID, state: row.state, now: at)
    }

    public struct Row: Codable, Hashable, Sendable, Identifiable {
        /// `runtime:sign-in`, or `runtime:‹CredentialKind›` for a key the Mac lends.
        public var credentialKey: String
        public var state: AllowanceState
        /// Why it cannot be used at all: not signed in, not installed. Nil when it can.
        public var unusable: String?

        public init(credentialKey: String, state: AllowanceState, unusable: String? = nil) {
            self.credentialKey = credentialKey
            self.state = state
            self.unusable = unusable
        }

        public var id: String { credentialKey }
        public var runtimeID: String { AllowanceState.runtimeID(of: credentialKey) }
        public func line(now: Date) -> String { PoolWords.state(state, now: now) }
    }
}

extension AllowanceState {
    /// The runtime a credential key is for: the part before the colon.
    public static func runtimeID(of credentialKey: String) -> String {
        String(credentialKey.split(separator: ":", maxSplits: 1).first ?? Substring(credentialKey))
    }

    public var runtimeID: String { Self.runtimeID(of: credentialKey) }
}
