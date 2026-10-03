import Foundation

/// Every runtime's state (065, US4): a row for each runtime the app finds,
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

    /// Whether this runtime's plan is spent, on any of its credentials. A chooser asks
    /// this to put a runtime in its out run: a spent plan cannot take a turn, but it is
    /// still worth naming rather than hiding, because that is the only way back to it.
    public func isOut(_ runtimeID: String) -> Bool {
        rows.contains { $0.runtimeID == runtimeID && $0.state.isOut }
    }

    /// Its first row's line, which is the Mac's own wording for what is wrong with it.
    /// Nil when nothing has happened to this runtime, or when nothing is known.
    public func note(for runtimeID: String) -> String? {
        guard let row = firstRow(runtimeID) else { return nil }
        return row.line(now: at)
    }

    /// A rate limit, which is not an out runtime: the runtime can still take a turn, and
    /// `isUsable` says so. It is a throttle all the same, and a chooser that says
    /// nothing about it reads as no throttle at all. Nor is a model out (#140): the
    /// runtime's other models work. Nil unless it is rate limited right now or a model
    /// is out, so a limit that has run out does not keep claiming to be one.
    public func availableNote(for runtimeID: String) -> String? {
        guard let row = firstRow(runtimeID) else { return nil }
        if case .rateLimited = row.state.current(now: at) { return row.line(now: at) }
        return PoolWords.modelsOut(row.state, now: at)
    }

    private func firstRow(_ runtimeID: String) -> Row? {
        rows.first { $0.runtimeID == runtimeID }
    }

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
        public func line(now: Date) -> String { PoolWords.stateWithModels(state, now: now) }
    }
}

extension AllowanceState {
    /// The runtime a credential key is for: the part before the colon.
    public static func runtimeID(of credentialKey: String) -> String {
        String(credentialKey.split(separator: ":", maxSplits: 1).first ?? Substring(credentialKey))
    }

    public var runtimeID: String { Self.runtimeID(of: credentialKey) }
}
