import Foundation

/// A time the daemon was not running, as the daemon that came after it worked it out
/// (#1219): when it started again, why the last one went, and since when nothing was
/// running, when that is known.
public struct RestartGap: Codable, Hashable, Sendable {
    public enum Reason: String, Codable, Hashable, Sendable, CaseIterable {
        /// The last daemon wrote that it stopped.
        case stopped
        /// The last daemon wrote that it was alive, and never that it stopped.
        case crashed
        /// Nothing was written before: a new root, or a daemon from before #1219.
        case firstStart = "first_start"
    }

    /// When this daemon started.
    public var at: Date
    public var reason: Reason
    /// The last daemon's clean stop, or the last time it said it was alive.
    public var downSince: Date?

    public init(at: Date, reason: Reason, downSince: Date?) {
        self.at = at
        self.reason = reason
        self.downSince = downSince
    }

    /// Worked out from what the last daemon left: its clean stop if it wrote one, or the
    /// last time it said it was alive.
    public init(at: Date, alive: DaemonAlive?) {
        guard let alive else {
            self.init(at: at, reason: .firstStart, downSince: nil)
            return
        }
        if let stopped = alive.stoppedAt {
            self.init(at: at, reason: .stopped, downSince: stopped)
        } else {
            self.init(at: at, reason: .crashed, downSince: alive.lastAlive)
        }
    }

    /// Seconds nothing was running, when known. Never less than nothing: a clock set
    /// back is not a gap.
    public var downFor: TimeInterval? {
        downSince.map { max(0, at.timeIntervalSince($0)) }
    }

    /// "3 min", "2 h 5 min", "40 s"; "unknown" when nothing says.
    public var downForWords: String {
        guard let seconds = downFor.map({ Int($0.rounded()) }) else { return "unknown" }
        if seconds < 60 { return "\(seconds) s" }
        let minutes = (seconds + 30) / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        if hours < 48 { return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min" }
        return "\(hours / 24) days"
    }

    /// The details `system.restarted` carries.
    public var details: [String: String] {
        var details = ["reason": reason.rawValue, "down_for_text": downForWords]
        if let downSince { details["down_since"] = ISO8601DateFormatter().string(from: downSince) }
        if let downFor { details["down_for"] = String(Int(downFor.rounded())) }
        return details
    }
}

/// `alive.json` in the root (#1219): the last time the daemon said it was alive, and when
/// it stopped, if it stopped cleanly. One small file, overwritten.
public struct DaemonAlive: Codable, Hashable, Sendable {
    public var lastAlive: Date
    public var stoppedAt: Date?

    public init(lastAlive: Date, stoppedAt: Date? = nil) {
        self.lastAlive = lastAlive
        self.stoppedAt = stoppedAt
    }

    /// How often a running daemon says so.
    public static let interval: Duration = .seconds(60)
}
