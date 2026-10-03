import Foundation

// Update now (#146): the Dashboard's own button for bringing its tiles up to date, and what
// the page says about the last time somebody did.

public extension DaemonAPI.Method {
    /// Update now: run the project's dashboard workflow, or start a one-off agent when it
    /// has none. Every client may (one grant, #111).
    static let dashboardUpdate = "dashboard/update"
}

/// Who brings a project's tiles up to date when somebody presses Update now, and where that
/// stands. Resolved by the host, which is the one that knows what is running.
public struct DashboardUpdate: Codable, Sendable, Hashable {
    /// The project's workflow labelled `dashboard`, or nil for the one-off agent.
    public var workflowID: String?
    /// The workflow's name, or the one-off agent's title.
    public var name: String
    /// A run or the one-off agent is going: the button reads Updating….
    public var isRunning: Bool
    /// The agent of the run going, or of the last one: the line's Open session.
    public var agentID: UUID?
    /// When the last update started, by the button or the workflow's own clock.
    public var lastStartedAt: Date?
    /// The last one ended stuck, or was stopped before it reported.
    public var lastFailed: Bool
    /// Why a press would start nothing, apart from running and the cooldown: the file
    /// waiting for approval, a ceiling, the folder gone.
    public var blocked: String?

    public init(workflowID: String? = nil, name: String = DashboardUpdate.oneOffTitle, isRunning: Bool = false,
                agentID: UUID? = nil, lastStartedAt: Date? = nil, lastFailed: Bool = false, blocked: String? = nil) {
        self.workflowID = workflowID
        self.name = name
        self.isRunning = isRunning
        self.agentID = agentID
        self.lastStartedAt = lastStartedAt
        self.lastFailed = lastFailed
        self.blocked = blocked
    }

    /// The label that makes a workflow the Dashboard's.
    public static let label = "dashboard"
    /// A press this soon after the last start is refused, so the button cannot be leant on.
    public static let cooldown: TimeInterval = 5 * 60
    public static let oneOffTitle = "Update the dashboard"

    /// When the button may start another, while that is still to come.
    public func readyAt(now: Date) -> Date? {
        guard let lastStartedAt else { return nil }
        let end = lastStartedAt.addingTimeInterval(Self.cooldown)
        return end > now ? end : nil
    }

    /// Whether a press would start something.
    public func canPress(now: Date) -> Bool {
        !isRunning && blocked == nil && readyAt(now: now) == nil
    }

    /// The line under the button: what is going, why it can't go, or how the last one went.
    public func line(now: Date, calendar: Calendar = .current) -> String? {
        if isRunning { return "\(name) is running" }
        if let blocked { return "Update now can't start: \(blocked)" }
        guard let lastStartedAt else { return nil }
        let when = Self.when(lastStartedAt, now: now, calendar: calendar)
        if lastFailed { return "The last update, \(when), did not finish" }
        if let ready = readyAt(now: now) {
            return "Last update \(when); again from \(Self.clock(ready, calendar: calendar))"
        }
        return "Last update \(when)"
    }

    /// "14:02" today, "2 Oct 14:02" before: 24-hour, as the rest of the app's times are.
    static func when(_ date: Date, now: Date, calendar: Calendar) -> String {
        guard !calendar.isDate(date, inSameDayAs: now) else { return clock(date, calendar: calendar) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date) + " " + clock(date, calendar: calendar)
    }

    static func clock(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// The one-off agent's prompt, for a project with no dashboard workflow (Alex, #146).
    public static let oneOffPrompt = """
        Bring this project's Dashboard up to date (Update now, #146). Run every command from \
        the project folder.

        1. Call `read_dashboard`.
        2. For each tile with a `source`, run that source again and set the tile with `set_tile`, \
        keeping its id, title, type, section, unit and `source` as they are. A tile kept by someone \
        else needs `take_over: true`; if that is refused, leave it and say so.
        3. Never invent a value. A tile with no `source`, or one whose source can't be read now, is \
        left alone.
        4. Read only, apart from `set_tile`: no builds, no tests, no file edits, no git changes, \
        no issue or PR edits. Never write `.agents/dashboard/` by hand.

        Finish with `done`, giving each tile's new value and any tile left alone and why. Then park.
        """
}
