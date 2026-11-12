import Foundation

/// Chats fetched before they are opened (#4795; spec 4777-fast, "a spinner only after
/// 300 ms"): the session under the pointer, after `hoverDelay`, and the rows before and
/// after the open one in the list in front. Opening one of them draws its page at once,
/// as the local copy draws, and its host's own page still comes and replaces it.
///
/// In memory only, and a few of them: a hover is not an open, so it does not push the
/// chats a person opened out of the local copy's last 20.
@MainActor
public final class OpeningPrefetch {
    /// How long the pointer stays on a row before its chat is fetched.
    public static let hoverDelay: Duration = .milliseconds(100)
    /// The openings held, the newest first out of the way last.
    public var kept = 8
    /// How long one is drawn for after it came: after that it is fetched again.
    public var fresh: Duration = .seconds(60)

    private var held: [UUID: (transcript: LocalCopy.Transcript, at: ContinuousClock.Instant)] = [:]
    private var fetching: Set<UUID> = []
    private let clock = ContinuousClock()

    public init() {}

    /// Fetches `session`'s opening page, unless one fresh enough is held or on its way. A
    /// fetch that fails holds nothing: opening it then loads as before. The fetch, when one
    /// starts.
    @discardableResult
    public func prefetch(_ session: UUID, fetch: @escaping @MainActor () async throws -> ChatOpening.Loaded) -> Task<Void, Never>? {
        if let got = held[session], clock.now - got.at < fresh { return nil }
        guard fetching.insert(session).inserted else { return nil }
        return Task { @MainActor [weak self] in
            let loaded = try? await fetch()
            guard let self else { return }
            self.fetching.remove(session)
            // A page without its turns would draw a chat without its summaries.
            guard let loaded, loaded.turnsFailure == nil else { return }
            self.hold(LocalCopy.Transcript(session: session, turns: loaded.turns, page: loaded.page, ask: loaded.ask))
        }
    }

    /// What is held of `session`, when it is fresh: taken, so it is drawn once.
    public func take(_ session: UUID) -> LocalCopy.Transcript? {
        guard let got = held.removeValue(forKey: session), clock.now - got.at < fresh else { return nil }
        return got.transcript
    }

    public func isHeld(_ session: UUID) -> Bool { held[session] != nil }

    /// Everything held goes: the pairing went.
    public func forget() {
        held = [:]
    }

    private func hold(_ transcript: LocalCopy.Transcript) {
        held[transcript.session] = (transcript, clock.now)
        while held.count > kept, let oldest = held.min(by: { $0.value.at < $1.value.at })?.key {
            held.removeValue(forKey: oldest)
        }
    }

    /// The rows before and after `session` in `list`, the list in front's order: the ones a
    /// person opens next with the arrow keys. None when it is not in the list.
    public static func neighbours(of session: UUID, in list: [UUID]) -> [UUID] {
        guard let at = list.firstIndex(of: session) else { return [] }
        return [at + 1, at - 1].filter(list.indices.contains).map { list[$0] }.filter { $0 != session }
    }
}
