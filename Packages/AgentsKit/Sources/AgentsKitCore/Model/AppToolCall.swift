import Foundation

/// One call an agent made to the app's own tools, as the daemon answered it (#47).
///
/// Kept beside the transcript, in `app-tools.jsonl`, because the transcript's tool calls
/// are the runtime's account of them: what the adapter said it called. This is the
/// daemon's: the method its MCP helper relayed, the arguments that came with it (the
/// token left out), and whether it was answered or refused, in the words the agent read.
/// The runtime assessment scores from this, so a runtime that claims a call it never made,
/// or never got an answer to, is caught.
public struct AppToolCall: Codable, Hashable, Sendable {
    public var at: Date
    /// The daemon method, such as `agents/finishTurn` or `leases/lease`.
    public var method: String
    public var ok: Bool
    public var arguments: JSONValue?
    /// The note the agent was given, or the refusal, cut to `answerLimit`.
    public var answer: String?
    /// An agent the call made, for `agents/startHelper`.
    public var agentID: UUID?
    /// How long the call was held, for the ones that wait (`ask_form`, `wait_for_event`).
    public var seconds: Double?

    public static let answerLimit = 2000

    public init(at: Date, method: String, ok: Bool, arguments: JSONValue? = nil,
                answer: String? = nil, agentID: UUID? = nil, seconds: Double? = nil) {
        self.at = at
        self.method = method
        self.ok = ok
        self.arguments = arguments
        self.answer = answer.map { String($0.prefix(Self.answerLimit)) }
        self.agentID = agentID
        self.seconds = seconds
    }

    /// The parameters as they are kept: everything but the token, which would let
    /// anybody who reads the file speak for the agent while it lives.
    public static func keptArguments(_ params: JSONValue?) -> JSONValue? {
        guard var fields = params?.objectValue else { return params }
        fields.removeValue(forKey: "token")
        return .object(fields)
    }
}
