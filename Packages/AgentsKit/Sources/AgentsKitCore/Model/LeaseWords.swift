import Foundation

/// Every sentence about a lease, in one place (036).
///
/// The agent reads the tool replies and repeats them to the person (FR-014), and the
/// person reads the notes in the transcript, so the words are part of the contract
/// (`contracts/lease-tools.md`, `contracts/daemon-api.md`) and are tested as such. Here,
/// in the half both platforms hold, so a phone and a Mac cannot say it two ways.
public enum LeaseWords {
    // MARK: Pieces

    /// A local wall-clock time, "14:05". Twenty-four hours whatever the locale: these
    /// are read by agents as well as people, and "2:05" is a question.
    public static func clock(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    public static func ordinal(_ n: Int) -> String {
        let tens = (n / 10) % 10, units = n % 10
        let suffix = tens == 1 ? "th" : (units == 1 ? "st" : units == 2 ? "nd" : units == 3 ? "rd" : "th")
        return "\(n)\(suffix)"
    }

    /// An agent as another agent or the person reads it: its title in quotes.
    public static func agentName(_ title: String?) -> String {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return "another agent"
        }
        return "\u{201C}\(title)\u{201D}"
    }

    /// Whole minutes between two times, rounded, never below one.
    public static func minutes(from start: Date, to end: Date) -> Int {
        max(1, Int((end.timeIntervalSince(start) / 60).rounded()))
    }

    /// Whole minutes left, rounded up, so a lease with ten seconds left says one.
    public static func minutesLeft(until end: Date, now: Date) -> Int {
        max(0, Int((end.timeIntervalSince(now) / 60).rounded(.up)))
    }

    // MARK: lease_resource

    public static let capped =
        " That is the longest a lease can run; extend it again before then if you need more."

    public static func granted(_ lease: Lease, capped isCapped: Bool) -> String {
        "You hold \(lease.displayName) until \(clock(lease.expiresAt)) "
            + "(\(minutes(from: lease.grantedAt, to: lease.expiresAt)) minutes). "
            + "Release it with release_resource when you are done."
            + (isCapped ? capped : "")
    }

    public static func grantedAfterWaiting(_ lease: Lease, waited seconds: Int, capped isCapped: Bool) -> String {
        "\(lease.displayName) is yours now, until \(clock(lease.expiresAt)) "
            + "(\(minutes(from: lease.grantedAt, to: lease.expiresAt)) minutes). You waited \(seconds) seconds."
            + (isCapped ? capped : "")
    }

    public static func extended(_ lease: Lease, capped isCapped: Bool) -> String {
        "You still hold \(lease.displayName), now until \(clock(lease.expiresAt))."
            + (isCapped ? capped : "")
    }

    public static func stillInLine(_ display: String, holder: String, until: Date, place: Int) -> String {
        "\(display) is held by \(holder) until \(clock(until)). You are \(ordinal(place)) in line "
            + "and keep your place. Call lease_resource again to go on waiting, or end your turn "
            + "\u{2014} you will be started again when it is yours."
    }

    public static func refused(_ display: String, holder: String, until: Date) -> String {
        "\(display) is held by \(holder) until \(clock(until)). You are not in line."
    }

    public static func stoppedWhileWaiting(_ display: String) -> String {
        "You were stopped, so you left the line for \(display)."
    }

    public static func removedWhileWaiting(_ display: String) -> String {
        "The person took you out of the line for \(display)."
    }

    public static let emptyName = "Nothing was leased: say which resource."
    public static let noConversation = "That conversation is not open any more, so nothing was leased."

    // MARK: release_resource

    public static func released(_ display: String, passedTo next: String?) -> String {
        next.map { "Released \(display). It has gone to \($0)." } ?? "Released \(display)."
    }

    public static func leftLine(_ display: String) -> String {
        "You left the line for \(display)."
    }

    public static func neither(_ display: String) -> String {
        "You neither hold nor are waiting for \(display); nothing changed."
    }

    // MARK: Notices, at the head of the next reply

    public static func notice(_ notice: LeaseNotice) -> String {
        switch notice.kind {
        case .endedByPerson:
            return "You no longer hold \(notice.displayName): the person ended your lease at \(clock(notice.at))."
        case .expired:
            return "You no longer hold \(notice.displayName): your lease ran out at \(clock(notice.at))."
        case .endingSoon(let expiresAt):
            return "Your lease on \(notice.displayName) ends at \(clock(expiresAt)). "
                + "Extend it with lease_resource if you still need it."
        }
    }

    // MARK: The wake prompt

    public static func wake(_ lease: Lease, askedAt: Date) -> String {
        "\(lease.displayName) is yours now. You hold it until \(clock(lease.expiresAt)) "
            + "(\(minutes(from: lease.grantedAt, to: lease.expiresAt)) minutes). You asked for it at "
            + "\(clock(askedAt)) and were waiting in line. Carry on with what you needed it for, "
            + "and release it with release_resource when you are done."
    }

    // MARK: Transcript notes (FR-016)

    public static func noteLeased(_ lease: Lease) -> String {
        "Leased \(lease.displayName) until \(clock(lease.expiresAt))."
    }

    public static func noteExtended(_ lease: Lease) -> String {
        "Extended the lease on \(lease.displayName) to \(clock(lease.expiresAt))."
    }

    /// Nil for an ending the agent said itself in the same breath (a `couldNotStart`
    /// note carries its reason, and is written where the reason is known).
    public static func noteEnded(_ lease: Lease, _ ending: LeaseEnding, at now: Date) -> String? {
        switch ending {
        case .released: return "Released \(lease.displayName)."
        case .expired: return "The lease on \(lease.displayName) ran out at \(clock(now))."
        case .endedByPerson: return "You ended this agent's lease on \(lease.displayName)."
        case .holderStopped: return "Let go of \(lease.displayName) when it was stopped."
        case .holderArchived: return "Let go of \(lease.displayName) when it was archived."
        case .couldNotStart: return nil
        }
    }

    public static func noteCouldNotStart(_ display: String, reason: String) -> String {
        "\(display) came to this agent but it could not be started (\(reason)), so it was passed on."
    }

    // MARK: The briefing (FR-015)

    public static let briefing = """
        Only one agent at a time should use a simulator, a browser or the screen (mouse, \
        keyboard, front window). Lease it with lease_resource before you use it and release \
        it with release_resource as soon as you are done; keep leases short and extend them, \
        and take several in the same order every time. If you are told you are in line, you \
        may end your turn: you will be started again when it is yours.
        """
}
