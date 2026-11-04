import Foundation

/// The daily summary's one control (#3351), for all folders: Off, Summary only or Summary and
/// checks (#3395), the time it runs, and how often the checks run. The home folder's ready-made
/// Daily summary and Daily checks workflows keep it, so a hand edit and the control agree. `dailySummary/settings` reads it, `dailySummary/setSettings` changes it, and
/// `dailySummary/changed` says when it changed.
public struct DailySummarySettings: Codable, Sendable, Hashable {
    /// How much it does: the checks run between summaries (#3395).
    public enum Mode: String, Codable, Sendable, Hashable, CaseIterable {
        case off
        case summary
        case summaryAndChecks

        public var label: String {
            switch self {
            case .off: "Off"
            case .summary: "Summary only"
            case .summaryAndChecks: "Summary and checks"
            }
        }
    }

    public var mode: Mode
    /// HH:MM in the host's time zone, on the hour or the half hour.
    public var at: String
    /// How many hours apart the checks run, from the summary's time and never at it.
    public var checksEvery: Int

    public init(mode: Mode = .off, at: String = "08:00", checksEvery: Int = 4) {
        self.mode = mode
        self.at = at
        self.checksEvery = checksEvery
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(Mode.self, forKey: .mode)
        at = try c.decode(String.self, forKey: .at)
        checksEvery = try c.decodeIfPresent(Int.self, forKey: .checksEvery) ?? 4
    }

    /// How often the checks can run: each divides the day evenly.
    public static let checksEveryChoices = [2, 3, 4, 6, 8, 12]

    /// How often, as a person reads it, such as "Every 4 hours".
    public static func everyLabel(_ hours: Int) -> String { "Every \(hours) hours" }

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
