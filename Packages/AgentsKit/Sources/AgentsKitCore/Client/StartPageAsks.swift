import Foundation

/// What the New session page asks its host as it opens (#1096), and which of those asks
/// still has no answer.
///
/// The page asks for its runtime's choices, the folder's personas and its worktrees.
/// An ask whose reply was lost with the link has no answer, the same as one that failed:
/// once the host answers again, each ask with no answer is asked again. The page used to
/// ask again only for choices that failed, so a reply lost on the way kept it on "Asking…"
/// with no Persona row until it was closed.
public struct StartPageAsks: Equatable, Sendable {
    public enum Ask: String, CaseIterable, Sendable {
        case choices
        case personas
        case worktrees
    }

    private var answered: Set<Ask> = []

    public init() {}

    /// The page opened again: nothing it was told before holds.
    public mutating func opened() {
        answered = []
    }

    /// `ask` went out again, or failed: it has no answer until it is answered.
    public mutating func asking(_ ask: Ask) {
        answered.remove(ask)
    }

    public mutating func answered(_ ask: Ask) {
        answered.insert(ask)
    }

    public func isAnswered(_ ask: Ask) -> Bool { answered.contains(ask) }

    /// Back in touch: every ask with no answer.
    public var toAskAgain: Set<Ask> { Set(Ask.allCases).subtracting(answered) }

    /// How long the page waits for each answer. A draft can start a runtime before it
    /// answers, as the web page's `agents/options` is given; a list is only a read.
    public static func patience(for method: String) -> Duration {
        method == DaemonAPI.Method.agentsOptions ? .seconds(120) : .seconds(30)
    }

    /// How often a page's call checks that the host is still there while it waits.
    public static let checkingEvery: Duration = .seconds(10)
}

public extension DaemonClient {
    /// A call a page waits on (#1096): it fails at once when its connection closes, the
    /// host is pinged every `every` while it waits and let go when it does not answer, and
    /// with no answer within `patience` it is `NoAnswer`. Never a wait for ever.
    func callWithin<T: Decodable>(_ patience: Duration, _ method: String, _ params: (some Encodable)?,
                                  checkingEvery every: Duration = StartPageAsks.checkingEvery,
                                  returning: T.Type) async throws -> T {
        try await DaemonClient.$patience.withValue(patience) {
            try await callWhileAnswering(method, params, checkingEvery: every)
        }.decode(T.self)
    }
}
