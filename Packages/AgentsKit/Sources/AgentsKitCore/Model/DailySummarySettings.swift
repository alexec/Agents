import Foundation

/// The daily summary's one control (#3351), for all folders: Off or Summary, and the time it
/// runs. The home folder's ready-made Daily summary workflow keeps it, so a hand edit and the
/// control agree. `dailySummary/settings` reads it, `dailySummary/setSettings` changes it, and
/// `dailySummary/changed` says when it changed.
public struct DailySummarySettings: Codable, Sendable, Hashable {
    /// How much it does. Summary and checks comes with the checks (#3192).
    public enum Mode: String, Codable, Sendable, Hashable, CaseIterable {
        case off
        case summary

        public var label: String {
            switch self {
            case .off: "Off"
            case .summary: "Summary only"
            }
        }
    }

    public var mode: Mode
    /// HH:MM in the host's time zone, on the hour or the half hour.
    public var at: String

    public init(mode: Mode = .off, at: String = "08:00") {
        self.mode = mode
        self.at = at
    }

    /// The times it can run at: every half hour of the day, as HH:MM.
    public static let times: [String] = (0..<48).map { String(format: "%02d:%02d", $0 / 2, $0 % 2 * 30) }

    /// A time as a person reads it, such as "8:00 AM", in this device's locale.
    public static func timeLabel(_ at: String) -> String {
        let parts = at.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2,
              let date = Calendar.current.date(from: DateComponents(hour: parts[0], minute: parts[1])) else { return at }
        return date.formatted(date: .omitted, time: .shortened)
    }
}
