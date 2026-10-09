import Foundation

/// A runtime's line about a blip it retries on its own (#394).
///
/// Cursor writes `Error: RetriableError: [unavailable] getaddrinfo ENOTFOUND api2.cursor.sh`
/// into its reply when the network drops, then retries and carries on. It arrives as the
/// agent's own words, so nothing else marks it, and it is not a failed turn: Cursor's only
/// turn-ending prefix is `Upgrade your plan to continue`.
///
/// While the line is the last thing the agent did, it may be what stopped the work, and
/// it stays. Once the agent carries on, it is a blip already got past, and the page drops
/// it the way it drops a passing line. The record keeps it either way.
///
/// Cursor does not always get past it: a turn can end on the line (#513). The daemon
/// then tells the agent to carry on, a few times, as `RetriedErrorPolicy` says.
public enum IntermittentError {
    /// Whether this text could hold such a line, cheaply, before looking line by line.
    public static func mayHold(_ text: String) -> Bool {
        text.contains(marker)
    }

    /// Whether this one line is a retried error and nothing else.
    public static func isLine(_ line: Substring) -> Bool {
        let trimmed = line.drop(while: \.isWhitespace)
        return trimmed.hasPrefix("Error: \(marker)") || trimmed.hasPrefix(marker)
    }

    /// Whether the last thing this text says is a retried error.
    public static func endsOn(_ text: String) -> Bool {
        guard mayHold(text) else { return false }
        let last = text.split(separator: "\n").last { !$0.allSatisfy(\.isWhitespace) }
        return last.map(isLine) ?? false
    }

    /// The text with its retried errors left out: every one when `all`, otherwise only
    /// those with something more of the message after them. Nil when nothing goes.
    public static func without(in text: String, all: Bool) -> String? {
        guard mayHold(text) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var dropped = false
        // From the end, so "followed" is known: whether anything said comes after.
        var followed = false
        for line in lines.reversed() {
            if isLine(line), all || followed {
                dropped = true
                continue
            }
            if !isLine(line), !line.allSatisfy(\.isWhitespace) { followed = true }
            kept.append(line)
        }
        guard dropped else { return nil }
        var result = kept.reversed().joined(separator: "\n")
        while result.contains("\n\n\n") { result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return result.trimmingCharacters(in: .newlines)
    }

    private static let marker = "RetriableError"
}

/// How a turn that ended on a retried error is carried on (#513): told to carry on after
/// each wait in turn, and stopped as a runtime error once they are used up.
public struct RetriedErrorPolicy: Hashable, Sendable {
    /// Waits before each try; their count is how many tries there are.
    public var delays: [TimeInterval]

    public static let standard = RetriedErrorPolicy(delays: [5, 30, 120])

    /// The wait before try `attempt` (from 0), or nil once the tries are used up.
    public func delay(forAttempt attempt: Int) -> TimeInterval? {
        delays.indices.contains(attempt) ? delays[attempt] : nil
    }
}
