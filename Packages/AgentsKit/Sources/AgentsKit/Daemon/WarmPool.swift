import Foundation

/// The runtimes kept running between turns, and how likely each is to be needed (#183).
///
/// A runtime let go at the end of every turn makes every reply a cold start: a process,
/// the ACP handshake, MCP servers and plugins, and `session/load`. Keeping every one
/// would hold hundreds of megabytes per finished session and keep nothing bounded. So a
/// few are kept, chosen by simple rules about how likely the person is to reply, and the
/// rest go as they always did. No learned model (#46): rules that can be read and tuned
/// from the daemon log.
public enum WarmPool {
    /// One warm runtime.
    public struct Entry: Sendable, Equatable {
        /// When it joined: its turn ended, or it was warmed on intent. What the score
        /// decays from, and what the ceiling counts from.
        public var since: Date
        /// When a window last showed intent: opened the session or typed in its box.
        public var intentAt: Date?

        public init(since: Date, intentAt: Date? = nil) {
            self.since = since
            self.intentAt = intentAt
        }
    }

    /// What the score is made from, gathered by the daemon for one session.
    public struct Signals: Sendable, Equatable {
        /// On screen, in front of the person, on some surface.
        public var watchedActive = false
        /// Open in a window that is not in front.
        public var watched = false
        /// It ended asking the person something.
        public var needsAnswer = false
        /// Finished and not looked at yet.
        public var unread = false
        /// The person has prompted it at least once: a chat, not a workflow's or an
        /// agent's errand.
        public var personsConversation = false
        public var parked = false
        public var lastPersonPrompt: Date?
        /// The person's usual gap between prompts here, when there are enough to say.
        public var typicalGap: TimeInterval?
        /// They have been away from the Mac (idle or locked) long enough to drain.
        public var personAway = false
        /// The app will carry it on by itself (#202): an open `wait_for_event`, or a block
        /// waiting on agents or a time. Its next turn is coming whether anyone is about.
        public var pendingWake = false

        public init() {}
    }

    /// After this long, it goes whatever its score.
    public static let ceiling: TimeInterval = 30 * 60
    /// The score halves every this long.
    public static let halfLife: TimeInterval = 10 * 60
    /// Intent counts for this long after it is shown.
    public static let intentLasts: TimeInterval = 5 * 60
    /// The person's last prompt counts as recent for this long.
    public static let recentPrompt: TimeInterval = 10 * 60
    /// A usual gap under this is a back-and-forth.
    public static let quickReplies: TimeInterval = 5 * 60
    /// Away this long before the pool drains to what is on screen.
    public static let awayDrainsAfter: TimeInterval = 3 * 60

    /// How likely a reply is soon. Zero means let it go now.
    public static func score(_ entry: Entry, _ signals: Signals, now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(entry.since))
        guard age < ceiling else { return 0 }
        let intent = entry.intentAt.map { now.timeIntervalSince($0) < intentLasts } ?? false
        let wanted = signals.watchedActive || intent
        // A session put down: nobody is expected, unless somebody is looking at it now.
        if signals.parked, !wanted { return 0 }
        // Away from the Mac: only what is in front of somebody on another surface is
        // kept, or what somebody has just opened or typed in there, which says they are,
        // or what the app itself will wake: that needs nobody about.
        if signals.personAway, !wanted, !signals.pendingWake { return 0 }
        // A workflow's or an agent's errand nobody chatted in: nobody is expected, unless
        // somebody is looking at it right now or it is waiting to be woken.
        if !wanted, !signals.pendingWake, !signals.personsConversation { return 0 }
        var points = 10.0
        if signals.watchedActive { points += 100 } else if signals.watched { points += 40 }
        if intent { points += 80 }
        if signals.pendingWake { points += 40 }
        if signals.needsAnswer { points += 60 }
        if let last = signals.lastPersonPrompt, now.timeIntervalSince(last) < recentPrompt { points += 50 }
        if let gap = signals.typicalGap, gap < quickReplies { points += 20 }
        if signals.unread { points += 20 }
        return points * pow(0.5, age / halfLife)
    }

    /// The person's usual gap between prompts, from their last few. Nil with fewer than
    /// three, where one long lunch would say too much.
    public static func typicalGap(_ times: [Date]) -> TimeInterval? {
        guard times.count >= 3 else { return nil }
        let gaps = zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }.sorted()
        return gaps[gaps.count / 2]
    }

    /// Which to let go, given each one's score, to keep at most `cap`: every zero, then
    /// the lowest until it fits. Ties go oldest first.
    public static func releases(_ scored: [(id: UUID, score: Double, since: Date)], cap: Int) -> [UUID] {
        var out = scored.filter { $0.score <= 0 }.map(\.id)
        let kept = scored.filter { $0.score > 0 }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.since > $1.since }
        if kept.count > cap { out += kept[max(0, cap)...].map(\.id) }
        return out
    }
}
