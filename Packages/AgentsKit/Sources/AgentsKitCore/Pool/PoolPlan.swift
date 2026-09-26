import Foundation

/// Where a chat goes when its runtime is out (052, FR-009, FR-016).
public enum PoolDecision: Hashable, Sendable {
    /// Carry on with this entry.
    case switchTo(PoolEntry)
    /// Nothing usable. The earliest known return, if any entry gave one.
    case everyoneOut(earliest: Date?)
    /// Carrying on is off: the pool is off or too small, or this chat's own switch is.
    case off
}

/// The whole rule for choosing the next entry, with no daemon in it.
public enum PoolPlan {
    /// - Parameters:
    ///   - current: the entry the chat is on (or is judged to be on).
    ///   - tried: credential keys already tried for this prompt; never gone back to.
    ///   - states: each credential's state, keyed by `AllowanceState.credentialKey`.
    ///   - unusable: why an entry cannot be used at all (not signed in, not installed),
    ///     or nil when it can.
    public static func next(current: PoolEntry, pool: PoolSettings, switchingOff: Bool,
                            states: [String: AllowanceState], tried: Set<String>,
                            unusable: (PoolEntry) -> String?, now: Date) -> PoolDecision {
        guard pool.isEffective, !switchingOff else { return .off }
        let currentKey = AllowanceState.credentialKey(for: current)
        let candidates = pool.entries.filter {
            let key = AllowanceState.credentialKey(for: $0)
            return key != currentKey && !tried.contains(key) && unusable($0) == nil
        }
        for entry in candidates {
            let key = AllowanceState.credentialKey(for: entry)
            guard let state = states[key] else { return .switchTo(entry) }
            if state.isUsable(now: now) { return .switchTo(entry) }
        }
        let returns = candidates.compactMap { states[AllowanceState.credentialKey(for: $0)]?.returnsAt }
            .filter { $0 > now }
        return .everyoneOut(earliest: returns.min())
    }
}
