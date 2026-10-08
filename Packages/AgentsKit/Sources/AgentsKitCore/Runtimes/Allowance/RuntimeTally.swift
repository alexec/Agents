import Foundation

/// What the sidebar's Runtimes row says (#379): how many runtimes can start a turn now,
/// out of how many are installed, and whether none can. One runtime being out does not
/// matter, the work goes on on the others; none working is the only thing worth a dot.
/// The window and the Remote read it here; the page has `runtimeTally` in runtimes.ts.
public struct RuntimeTally: Hashable, Sendable {
    /// Installed, available and not out: the start form's Available run.
    public var working: Int
    /// Installed: found on the host, whether or not it can start (signed out, failed).
    /// A runtime that is not there, or is still being installed, was never in.
    public var total: Int

    public init(working: Int, total: Int) {
        self.working = working
        self.total = total
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
        self.init(working: working.count, total: installed.count)
    }

    public var noneWorking: Bool { working == 0 }

    /// `2/3`.
    public var words: String { "\(working)/\(total)" }
}
