import Foundation

/// What an agent told the person with `notify` (#2805), on the record where it called it:
/// the notification's words, what became of it, and, in the cool-down, when the next can go.
public struct SentNotice: Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Hashable, Sendable {
        /// Sent to where the person is.
        case sent
        /// Not sent: the person was looking at this chat.
        case shownHere
        /// Not sent: the person muted the session (#2003).
        case muted
        /// Not sent: no notice was left until `nextAt`.
        case coolingDown
    }

    /// Where a notice went (#2860): the computer is the Mac window or the web page.
    public enum Device: String, Codable, Hashable, Sendable {
        case computer
        case iPhone
        case iPad
        case device
    }

    public var title: String
    public var body: String?
    public var outcome: Outcome
    public var nextAt: Date?
    /// Where it went, from the `noticeDelivered` after it; nil until the host knows.
    public var to: Device?

    public init(title: String, body: String? = nil, outcome: Outcome, nextAt: Date? = nil, to: Device? = nil) {
        self.title = title
        self.body = body
        self.outcome = outcome
        self.nextAt = nextAt
        self.to = to
    }

    /// What became of it, in the words every client shows after the time. The cool-down's
    /// are the agent's own: the time it was told.
    public func outcomeText(timeStyle: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }) -> String {
        switch outcome {
        case .sent:
            switch to {
            case nil: return "Sent"
            case .computer: return "Sent to the computer"
            case .iPhone: return "Sent to iPhone"
            case .iPad: return "Sent to iPad"
            case .device: return "Sent to a device"
            }
        case .shownHere: return "Shown here"
        case .muted: return "Muted: not sent"
        case .coolingDown:
            guard let nextAt else { return "Not sent: in the cool-down" }
            return "Not sent: the next notice can go at \(timeStyle(nextAt))"
        }
    }
}

/// Where the notice recorded as entry `notice` went (#2860), recorded after it once its
/// host knew: drawn on that notice's line.
public struct NoticeDelivery: Codable, Hashable, Sendable {
    public var notice: UUID
    public var to: SentNotice.Device

    public init(notice: UUID, to: SentNotice.Device) {
        self.notice = notice
        self.to = to
    }
}
