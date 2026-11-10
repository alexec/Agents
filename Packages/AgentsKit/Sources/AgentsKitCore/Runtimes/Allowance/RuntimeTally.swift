import Foundation

/// What the sidebar's Runtimes row says (#379): how many runtimes can start a turn now,
/// out of how many are installed, and whether none can. One runtime being out does not
/// matter, the work goes on on the others; none working is the only thing worth a dot,
/// and an allowance nearly used up the only thing worth the warning tint (#3956).
/// The window and the Remote read it here; the page has `runtimeTally` in runtimes.ts.
public struct RuntimeTally: Hashable, Sendable {
    /// Installed, available and not out: the start form's Available run.
    public var working: Int
    /// Installed: found on the host, whether or not it can start (signed out, failed).
    /// A runtime that is not there, or is still being installed, was never in.
    public var total: Int
    /// Available runtimes whose allowance is nearly used (#3956): less than 10% left, or
    /// the runtime warned with no amount. The row's icon goes orange and a grey line names
    /// them, unless none work, when it is red as before.
    public var low: [Low]

    public init(working: Int, total: Int, low: [Low] = []) {
        self.working = working
        self.total = total
        self.low = low
    }

    /// Nil until the runtimes have been listed: not yet known is not none.
    public init?(_ runtimes: [RuntimeStatus], allowances: RuntimeAllowances?) {
        guard !runtimes.isEmpty else { return nil }
        let installed = runtimes.filter {
            switch $0.availability {
            case .available, .needsSignIn, .failed: return true
            case .missing, .installing, .installFailed: return false
            }
        }
        let working = installed.filter {
            $0.availability.isAvailable && $0.isOut != true && allowances?.isOut($0.id) != true
        }
        let low = installed.filter { $0.availability.isAvailable }.compactMap { runtime -> Low? in
            guard let allowances,
                  let reading = allowances.row(runtime.id, account: nil)?.state.reading,
                  reading.isCurrent(now: allowances.at) else { return nil }
            if let used = reading.usedFraction, used >= Self.lowUsed { return Low(runtimeID: runtime.id, left: 1 - used) }
            return reading.nearlySpent && reading.usedFraction == nil ? Low(runtimeID: runtime.id, left: nil) : nil
        }
        self.init(working: working.count, total: installed.count, low: low)
    }

    /// Used from here on is low: less than 10% left (Alex, #3956), not the Runtimes bar's 80%.
    public static let lowUsed = 0.9

    /// One runtime with little allowance left.
    public struct Low: Hashable, Sendable {
        public var runtimeID: String
        /// From 0 to 1; nil when the runtime said it is nearly used up and no amount.
        public var left: Double?

        public init(runtimeID: String, left: Double?) {
            self.runtimeID = runtimeID
            self.left = left
        }
    }

    /// Orange, not red: some work, and one of them is nearly used up.
    public var isLow: Bool { !noneWorking && !low.isEmpty }

    /// The row's grey line (#3956): `Claude: 8% left`, `Claude: nearly used up`, or for two
    /// or more `Claude, Codex: low allowance`. Nil when nothing is low or none work.
    public var lowWords: String? {
        guard isLow else { return nil }
        guard low.count == 1, let one = low.first else {
            return low.map { PoolWords.runtimeName($0.runtimeID) }.joined(separator: ", ") + ": low allowance"
        }
        let name = PoolWords.runtimeName(one.runtimeID)
        guard let left = one.left else { return "\(name): nearly used up" }
        return "\(name): \(Int((left * 100).rounded()))% left"
    }

    public var noneWorking: Bool { working == 0 }

    /// `2/3`.
    public var words: String { "\(working)/\(total)" }
}
