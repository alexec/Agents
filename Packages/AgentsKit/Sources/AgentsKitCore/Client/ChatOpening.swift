import Foundation

/// Why a chat's history did not load, or only partly (#400): said in the chat, with a
/// way to try again, rather than leaving it blank.
public struct TranscriptLoadFailure: Hashable, Sendable {
    /// Nothing arrived, so the chat has nothing to show; or only its earlier turns did
    /// not, and the chat shows its last page without them.
    public var nothingLoaded: Bool
    public var reason: String

    public init(nothingLoaded: Bool, reason: String) {
        self.nothingLoaded = nothingLoaded
        self.reason = reason
    }

    /// What the chat says.
    public var sentence: String {
        nothingLoaded ? "This chat's history did not load: \(reason)"
            : "The earlier turns did not load: \(reason)"
    }
}

/// How every client opens a chat (#90, #400): its last few finished turns as summaries,
/// then the transcript from where the turn in progress starts.
public enum ChatOpening {
    public struct Loaded: Sendable {
        public var turns: TurnsPage
        public var page: TranscriptPage
        /// The turns could not be read, so `page` is the end of the whole transcript and
        /// there are no summaries. The chat opens on it and says so.
        public var turnsFailure: String?
    }

    /// The opening page. Throws when the transcript itself did not come.
    ///
    /// A host too old to keep turns gives the lot, which is not a failure. Any other
    /// failure of the turns used to be the same silent empty list, and the chat then
    /// showed its last page with nothing before it and no word why.
    public static func load(turns: () async throws -> TurnsPage,
                            transcript: (_ from: Int) async throws -> TranscriptPage,
                            describe: (any Error) -> String = { String(describing: $0) },
                            isolation: isolated (any Actor)? = #isolation) async throws -> Loaded {
        let opening: TurnsPage
        var turnsFailure: String?
        do {
            opening = try await turns()
        } catch {
            if (error as? JSONRPCError)?.code != JSONRPCError.methodNotFound { turnsFailure = describe(error) }
            opening = TurnsPage(turns: [], firstTurn: 0, openStart: 0)
        }
        let page = try await transcript(opening.openStart)
        return Loaded(turns: opening, page: page, turnsFailure: turnsFailure)
    }
}

extension AgentsModel {
    /// An opening page put on screen, if `load` is still the latest asked for: the page,
    /// and what of it did not come.
    @discardableResult
    public func takeOpening(_ loaded: ChatOpening.Loaded, load: Int) -> Bool {
        guard isLatestTranscriptLoad(load) else { return false }
        replaceTurns(with: loaded.turns)
        replaceTranscript(with: loaded.page)
        if let reason = loaded.turnsFailure {
            noteTranscriptLoadFailed(TranscriptLoadFailure(nothingLoaded: false, reason: reason))
        }
        return true
    }

    /// The opening page did not come. Said only while `load` is the latest: a newer
    /// load is already on its way, and its answer is the one that counts.
    public func failOpening(_ reason: String, load: Int) {
        guard isLatestTranscriptLoad(load) else { return }
        noteTranscriptLoadFailed(TranscriptLoadFailure(nothingLoaded: true, reason: reason))
    }
}
