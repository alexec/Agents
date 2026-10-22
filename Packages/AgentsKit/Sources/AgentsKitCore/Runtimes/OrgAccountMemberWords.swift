import Foundation

/// What a member sees of an org account on every client (#999, slice 3): its allowance, the
/// runtime's **Reaches the Model By**, **Continue in New** and a reported cost.
/// `Web/src/model/runtimes.ts` says the same on the web page.
public extension OrgAccountWords {
    /// The runtime's account for new sessions (spec FR-016, FR-024).
    static let reachesTheModelBy = "Reaches the Model By"
    /// The runtime's own sign-in, as a choice of **Reaches the Model By**.
    static let ownSignIn = "Your Own Sign-In"
    static let reachesFoot = "New sessions use this account. You can still choose another when you start one."
    /// The chat's button on a session whose account the organisation removed or refuses.
    static let continueInNew = "Continue in New"

    /// An org account's allowance line (spec D12, FR-025): it has no plan reading, so
    /// "Organisation · No plan limit · 12,000 tokens today", or "Out until 14:05" after the
    /// provider's rate-limit answer. Any other state is the Pool page's own line.
    static func allowance(_ state: AllowanceState, tokensToday: Int?, now: Date) -> String {
        let tokens = tokensToday.map { "\(OrgPolicyWords.tokens($0)) today" }
        let head: String = switch state.current(now: now) {
        case .available: noPlanLimit
        case .rateLimited(let until): "Out until \(PoolWords.time(until, now: now))"
        case .out(let until?, _, _): "Out until \(PoolWords.time(until, now: now))"
        case .out: PoolWords.state(state, now: now)
        }
        return [head, tokens].compactMap { $0 }.joined(separator: " · ")
    }

    /// After a cost on an org account: the runtime's own price, not what the organisation
    /// pays (spec D12, FR-025). "list price, as Claude reports it".
    static func listPrice(_ runtimeID: String) -> String {
        "list price, as \(OrgPolicyWords.runtimeName(runtimeID)) reports it"
    }
}

public extension RuntimeAllowances.Row {
    /// The row's state line: an org account's own (#999), else the Pool page's.
    func memberLine(now: Date) -> String {
        isOrganisation ? OrgAccountWords.allowance(state, tokensToday: tokensToday, now: now) : line(now: now)
    }
}

public extension Agent {
    /// A session on an org account (#999): its account id is `org:<route id>`.
    var isOnOrgAccount: Bool { accountID?.hasPrefix("org:") == true }

    /// A cost figure, and on an org account whose price it is (spec FR-025):
    /// "$0.42 · list price, as Claude reports it".
    func priced(_ figure: String) -> String {
        isOnOrgAccount ? "\(figure) · \(OrgAccountWords.listPrice(runtimeID))" : figure
    }
}
