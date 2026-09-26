import Foundation

/// A chat waiting for an allowance to come back (052, US4; research R8): every runtime in
/// the pool was out, and one said when it returns. At that time the chat carries on with
/// the words it was refused, sent again once.
public struct AllowanceWait: Codable, Hashable, Sendable {
    /// When the first entry is due back.
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
    /// often the first to return. Only entries that can be used, and only times still
    /// ahead, and only a time the provider gave: the app's own one-hour retry is not a return.
    /// Nil when none has said when.
    public static func earliestReturn(current: PoolEntry, pool: PoolSettings, states: [String: AllowanceState],
                                      unusable: (PoolEntry) -> String?, now: Date) -> (at: Date, entry: PoolEntry)? {
        var entries = pool.entries.filter { unusable($0) == nil }
        if !entries.contains(where: { AllowanceState.credentialKey(for: $0) == AllowanceState.credentialKey(for: current) }) {
            entries.insert(current, at: 0)
        }
        return entries.compactMap { entry -> (Date, PoolEntry)? in
            guard let back = states[AllowanceState.credentialKey(for: entry)]?.knownReturn, back > now else { return nil }
            return (back, entry)
        }
        .min { $0.0 < $1.0 }
        .map { (at: $0.0, entry: $0.1) }
    }
}
