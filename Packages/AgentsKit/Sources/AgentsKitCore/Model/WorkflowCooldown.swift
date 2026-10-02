import Foundation

/// How long a workflow waits after one run starts before the next may (#103).
///
/// `cooldown: 15m` in the file. Written as a number and a unit, or several of them,
/// `1h30m`: minutes, hours or days, because the clock that releases a held fire looks
/// every fifteen seconds and a cooldown in seconds would promise more than it keeps.
public enum WorkflowCooldown {
    /// The key, as the file spells it.
    public static let key = "cooldown"

    private static let units: [Character: TimeInterval] = ["m": 60, "h": 60 * 60, "d": 24 * 60 * 60]

    /// The length the text names, or the sentence saying why it names none.
    public static func parse(_ text: String) -> Result<TimeInterval, Failure> {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        var total: TimeInterval = 0
        var digits = ""
        var sawUnit = false
        for character in trimmed where character != " " {
            if character.isASCII, character.isNumber {
                digits.append(character)
            } else if let unit = units[character], let count = Int(digits) {
                total += TimeInterval(count) * unit
                digits = ""
                sawUnit = true
            } else {
                return .failure(Failure(text: text))
            }
        }
        guard digits.isEmpty, sawUnit else { return .failure(Failure(text: text)) }
        guard total >= 60 else { return .failure(Failure(text: text, isZero: true)) }
        return .success(total)
    }

    /// Why a `cooldown:` could not be read, as a sentence for the page.
    public struct Failure: Error, Hashable, Sendable {
        public var text: String
        public var isZero = false

        public var message: String {
            isZero
                ? "`cooldown:` must be at least a minute, not \"\(text)\""
                : "`cooldown:` must be a length of time, like 15m, 2h or 1d, not \"\(text)\""
        }
    }

    /// The length as the file writes it: `15m`, `2h`, `1h30m`, `1d`.
    public static func fileText(_ length: TimeInterval) -> String {
        var left = Int(length / 60)
        var parts: [String] = []
        for (unit, minutes) in [("d", 24 * 60), ("h", 60), ("m", 1)] where left >= minutes {
            parts.append("\(left / minutes)\(unit)")
            left %= minutes
        }
        return parts.isEmpty ? "0m" : parts.joined()
    }

    /// The length in words: `15 minutes`, `2 hours`, `1 hour 30 minutes`, `1 day`.
    public static func words(_ length: TimeInterval) -> String {
        var left = Int(length / 60)
        var parts: [String] = []
        for (unit, minutes) in [("day", 24 * 60), ("hour", 60), ("minute", 1)] where left >= minutes {
            let count = left / minutes
            parts.append("\(count) \(unit)\(count == 1 ? "" : "s")")
            left %= minutes
        }
        return parts.joined(separator: " ")
    }
}
