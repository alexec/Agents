import Foundation

/// A control plane's address refused the connection outright, before the key exchange
/// (1003 CL-002/CL-003): a suspended hosted account, or one over its plan's limit
/// (#2224). `line` is the words the address answered, at most 200 characters, read as
/// the connection's error in pairing and in the away strip, in place of "can't reach".
///
/// Unlike `ControlAuth.Refusal`, which the control plane answers after it opens the
/// socket, this is read from the HTTP answer to the dial itself: its `Agents-Refusal`
/// header says there is a line to show, and the body carries it.
public struct ControlRefusal: Error, Sendable, CustomStringConvertible, Equatable {
    public var line: String
    public init(line: String) { self.line = line }
    public var description: String { line }

    /// The header that says an HTTP answer to a dial carries a refusal's line, and how
    /// long a line this device ever shows (a plan's words are the longest, comfortably
    /// under it).
    public static let header = "Agents-Refusal"
    public static let maxLineLength = 200

    /// The web address a refusal's line names, such as the account page where a plan is
    /// upgraded or a suspension is explained (#3153), so a client can offer it as a link.
    /// Only `https` addresses: the line comes from outside.
    public static func link(in line: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        return detector.matches(in: line, range: NSRange(line.startIndex..., in: line))
            .compactMap(\.url)
            .first { $0.scheme == "https" }
    }
}
