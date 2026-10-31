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
}
