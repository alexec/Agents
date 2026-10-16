import Foundation

/// A chat app that reaches the person (#1012): what every adapter says, so Slack (#1009)
/// is the first of several and the next plugs in the same way.
///
/// - **Send:** a Needs You message, the question and its options.
/// - **Read:** a reply tied to that message, a button or text, is heard as the answer.
/// - **Who:** the one identity tied to the grant (#111). An adapter hears nobody else.
/// - **How it connects:** the adapter's own business. Slack's dials out (Socket Mode).
public protocol NeedsChannel: AnyObject, Sendable {
    /// Connects, and keeps connected until `stop`. Everything heard from the tied person
    /// goes to `heard`; how the connection stands goes to `status`.
    func start(heard: @escaping @Sendable (ChannelReply) async -> Void,
               status: @escaping @Sendable (ChannelStatus) async -> Void) async
    func stop() async
    /// One waiting question, out to the person. `message.key` names it from now on.
    func send(_ message: NeedMessage) async throws
    /// The question is over: its buttons go, and `saying` says why.
    func close(_ key: String, saying: String) async
    /// A note beside the question, which stays open: an answer that would not do.
    func note(_ key: String, _ text: String) async
}

/// What a channel draws for one waiting question.
public struct NeedMessage: Sendable, Hashable {
    /// Unique to the question: the host and the need.
    public var key: String
    /// The project and the conversation: "work · Fix the test".
    public var heading: String
    public var question: String
    /// More about it, where the agent said more.
    public var detail: String?
    /// One button each. Empty for a question answered in words only.
    public var options: [Option]
    /// Whether a reply in words answers it.
    public var takesText: Bool
    /// A form this channel can't draw (several questions, a number, a page to open): the
    /// question is shown, and the person is told to answer it in Agents.
    public var answerElsewhere: Bool

    public struct Option: Sendable, Hashable {
        public var value: String
        public var title: String
        public init(value: String, title: String) {
            self.value = value
            self.title = title
        }
    }

    public init(key: String, heading: String, question: String, detail: String? = nil, options: [Option] = [],
                takesText: Bool = true, answerElsewhere: Bool = false) {
        self.key = key
        self.heading = heading
        self.question = question
        self.detail = detail
        self.options = options
        self.takesText = takesText
        self.answerElsewhere = answerElsewhere
    }
}

/// What the tied person said to a question.
public enum ChannelReply: Sendable, Hashable {
    /// A button: the option's value.
    case picked(key: String, value: String)
    /// Words in the question's thread.
    case wrote(key: String, text: String)

    public var key: String {
        switch self {
        case .picked(let key, _), .wrote(let key, _): key
        }
    }
}

/// How a channel's connection stands, for Settings.
public enum ChannelStatus: Sendable, Hashable {
    case connecting
    case connected
    /// Words a person can act on: a token refused, a scope missing. It tries again later.
    case failed(String)
}
