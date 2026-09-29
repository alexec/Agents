import Foundation

/// A chat waiting for an allowance to come back (052, US4; research R8): every runtime in
/// the pool was out, and one is due an availability check. Once a check passes the chat
/// carries on with the words it was refused, sent again once.
public struct AllowanceWait: Codable, Hashable, Sendable {
    /// When the first entry is due a check; moved on while none has passed.
    public var resumeAt: Date
    /// That entry, and its runtime, for saying which.
    public var entryID: UUID?
    public var runtimeID: String
    /// What was refused, to be sent again.
    public var text: String
    public var blocks: [ContentBlock]
    public var from: PromptOrigin

    public init(resumeAt: Date, entryID: UUID?, runtimeID: String, text: String,
                blocks: [ContentBlock], from: PromptOrigin) {
        self.resumeAt = resumeAt
        self.entryID = entryID
        self.runtimeID = runtimeID
        self.text = text
        self.blocks = blocks
        self.from = from
    }

    public func isDue(now: Date) -> Bool { resumeAt <= now }
}

extension PoolPlan {
    /// The first entry due back, when every one is out: the chat's own included, which is
    /// often the first to return. A check is an attempt, so a failed one moves the
    /// wait to the next check instead of sending the refused prompt unverified.
    public static func earliestReturn(current: PoolEntry, pool: PoolSettings, states: [String: AllowanceState],
                                      unusable: (PoolEntry) -> String?, now: Date) -> (at: Date, entry: PoolEntry)? {
        var entries = pool.entries.filter { unusable($0) == nil }
        if !entries.contains(where: { AllowanceState.credentialKey(for: $0) == AllowanceState.credentialKey(for: current) }) {
            entries.insert(current, at: 0)
        }
        return entries.compactMap { entry -> (Date, PoolEntry)? in
            guard let state = states[AllowanceState.credentialKey(for: entry)],
                  case .out(_, let back?, _) = state.status, back > now else { return nil }
            return (back, entry)
        }
        .min { $0.0 < $1.0 }
        .map { (at: $0.0, entry: $0.1) }
    }
}
