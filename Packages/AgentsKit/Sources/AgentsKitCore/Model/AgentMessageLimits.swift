import Foundation

/// The brakes on `message_agent` (#560). Any agent may message any session in its
/// project; these are what stop that running away.
public enum AgentMessageLimits {
    /// The most a message may say, in characters. Long enough for a brief, short enough
    /// that a message is not a way to hand another agent a file.
    public static let characters = 4_000

    /// How many messages one agent may send in an hour, as `publish_event` (042).
    public static let perHour = 30

    /// How many messages between agents may follow one another with no prompt from the
    /// person. Two agents answering each other would otherwise go on for ever, a turn's
    /// cost each time. The third is the last; the person's next prompt starts the count again.
    public static let hops = 3
}
