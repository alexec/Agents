import Foundation

/// `messages/conversations` and `messages/read` (#4343): the conversations of a machine's messaging
/// connectors, the ones that follow the messaging contract (docs/reference/messaging-contract.md),
/// and one conversation's messages. The data behind the Messages page (#4344); `messages/reply`
/// is the person's own reply from it (#4345).
public extension DaemonAPI {
    /// Who sent a channel message (#1762): the channel's kind (slack, email) and the sender on it.
    struct ChannelSender: Codable, Sendable, Hashable {
        public struct DKIM: Codable, Sendable, Hashable {
            public var result: String
            public var domain: String?

            public init(result: String, domain: String? = nil) {
                self.result = result
                self.domain = domain
            }
        }

        public var channel: String
        public var identity: String
        public var name: String?
        public var email: String?
        public var dkim: DKIM?

        public init(channel: String, identity: String, name: String? = nil, email: String? = nil, dkim: DKIM? = nil) {
            self.channel = channel
            self.identity = identity
            self.name = name
            self.email = email
            self.dkim = dkim
        }
    }

    /// One conversation as a connector's `list_conversations` gave it: a channel, a space, a direct
    /// chat or a mail thread.
    struct MessagingConversation: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable, Hashable { case channel, direct, thread }

        /// The service: slack, email, googlechat, whatsapp, or the server's own word.
        public var source: String
        /// The server's id, which `messages/read` takes. Opaque.
        public var id: String
        public var title: String
        public var kind: Kind
        /// The service's own count of unread messages; nil when it does not say.
        public var unread: Int?
        /// The newest message's time, RFC 3339 as the connector wrote it (not a `WireDate`).
        public var lastActivity: String?
        public var link: String?

        public var lastActivityDate: Date? { lastActivity.flatMap(MessagesList.date) }

        public init(source: String, id: String, title: String, kind: Kind, unread: Int? = nil,
                    lastActivity: String? = nil, link: String? = nil) {
            self.source = source
            self.id = id
            self.title = title
            self.kind = kind
            self.unread = unread
            self.lastActivity = lastActivity
            self.link = link
        }
    }

    /// One message of a conversation. `text` is outside content: drawn as Markdown that loads nothing (no HTML, no image from the network).
    struct MessagingMessage: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var conversation: String
        public var sender: ChannelSender
        /// RFC 3339, as the connector wrote it (not a `WireDate`).
        public var time: String
        public var text: String
        public var thread: String?
        public var link: String?

        public var date: Date? { MessagesList.date(time) }

        public init(id: String, conversation: String, sender: ChannelSender, time: String, text: String,
                    thread: String? = nil, link: String? = nil) {
            self.id = id
            self.conversation = conversation
            self.sender = sender
            self.time = time
            self.text = text
            self.thread = thread
            self.link = link
        }
    }

    struct MessagesConversationsRequest: Codable, Sendable, Hashable {
        public var folder: String?
        public var cursor: String?
        public var limit: Int?
        public var unread: Bool?

        public init(folder: String? = nil, cursor: String? = nil, limit: Int? = nil, unread: Bool? = nil) {
            self.folder = folder
            self.cursor = cursor
            self.limit = limit
            self.unread = unread
        }
    }

    /// One conversation of the list: the connector it is on (its name in mcp.json, and a folder that
    /// reaches it), and the conversation. `replyAs` is who a reply goes as (the Slack bot, the
    /// WhatsApp number); nil when the connector cannot send, so the page has no reply field (#4345).
    struct MessagesConversation: Codable, Sendable, Hashable {
        public var server: String
        public var folder: String
        public var conversation: MessagingConversation
        public var replyAs: String?

        public init(server: String, folder: String, conversation: MessagingConversation, replyAs: String? = nil) {
            self.server = server
            self.folder = folder
            self.conversation = conversation
            self.replyAs = replyAs
        }
    }

    /// A connector the list could not read, and why.
    struct MessagesError: Codable, Sendable, Hashable {
        public var server: String
        public var folder: String
        public var message: String

        public init(server: String, folder: String, message: String) {
            self.server = server
            self.folder = folder
            self.message = message
        }
    }

    /// A page of the conversations, the newest first. `cursor` is the next page; nil at the end.
    struct MessagesConversations: Codable, Sendable, Hashable {
        public var conversations: [MessagesConversation]
        public var cursor: String?
        public var errors: [MessagesError]?

        public init(conversations: [MessagesConversation] = [], cursor: String? = nil, errors: [MessagesError]? = nil) {
            self.conversations = conversations
            self.cursor = cursor
            self.errors = errors
        }
    }

    struct MessagesReadRequest: Codable, Sendable, Hashable {
        public var server: String
        public var folder: String
        public var conversation: String
        public var cursor: String?
        public var thread: String?
        public var limit: Int?

        public init(server: String, folder: String, conversation: String, cursor: String? = nil,
                    thread: String? = nil, limit: Int? = nil) {
            self.server = server
            self.folder = folder
            self.conversation = conversation
            self.cursor = cursor
            self.thread = thread
            self.limit = limit
        }
    }

    /// A page of a conversation's messages, the newest first. `cursor` is the older page.
    struct MessagesRead: Codable, Sendable, Hashable {
        public var server: String
        public var folder: String
        public var conversation: String
        public var messages: [MessagingMessage]
        public var cursor: String?
        public var untrusted: Bool

        public init(server: String, folder: String, conversation: String, messages: [MessagingMessage] = [],
                    cursor: String? = nil, untrusted: Bool = true) {
            self.server = server
            self.folder = folder
            self.conversation = conversation
            self.messages = messages
            self.cursor = cursor
            self.untrusted = untrusted
        }
    }
}

public extension DaemonAPI {
    /// The person's reply to a conversation (#4345); `thread`: the thread to answer in.
    struct MessagesReplyRequest: Codable, Sendable, Hashable {
        public var server: String
        public var folder: String
        public var conversation: String
        public var thread: String?
        public var text: String

        public init(server: String, folder: String, conversation: String, thread: String? = nil, text: String) {
            self.server = server
            self.folder = folder
            self.conversation = conversation
            self.thread = thread
            self.text = text
        }
    }

    /// The message the connector sent.
    struct MessagesReplied: Codable, Sendable, Hashable {
        public var server: String
        public var folder: String
        public var conversation: String
        public var message: MessagingMessage

        public init(server: String, folder: String, conversation: String, message: MessagingMessage) {
            self.server = server
            self.folder = folder
            self.conversation = conversation
            self.message = message
        }
    }
}

public extension DaemonAPI.Method {
    /// `MessagesConversationsRequest` → `MessagesConversations`, `MessagesReadRequest` → `MessagesRead` (#4343),
    /// `MessagesReplyRequest` → `MessagesReplied` (#4345).
    static let messagesConversations = "messages/conversations"
    static let messagesRead = "messages/read"
    static let messagesReply = "messages/reply"
}

/// The Messages page (#4344): every machine's conversations in one list, the newest first, and its
/// words, the same on the Mac; the web page's are `Web/src/model/messages.ts`.
public enum MessagesList {
    /// One machine's answer, or why it gave none.
    public struct HostConversations: Sendable, Hashable {
        public var host: MachineRef
        public var name: String
        public var conversations: [DaemonAPI.MessagesConversation]
        public var cursor: String?
        public var errors: [DaemonAPI.MessagesError]
        /// The machine did not answer: why.
        public var problem: String?

        public init(host: MachineRef, name: String, conversations: [DaemonAPI.MessagesConversation] = [],
                    cursor: String? = nil, errors: [DaemonAPI.MessagesError] = [], problem: String? = nil) {
            self.host = host
            self.name = name
            self.conversations = conversations
            self.cursor = cursor
            self.errors = errors
            self.problem = problem
        }
    }

    /// One row: a conversation and the machine to read it on.
    public struct Row: Sendable, Hashable, Identifiable {
        public var host: MachineRef
        public var item: DaemonAPI.MessagesConversation

        public init(host: MachineRef, item: DaemonAPI.MessagesConversation) {
            self.host = host
            self.item = item
        }

        public var conversation: DaemonAPI.MessagingConversation { item.conversation }
        /// The same conversation from two machines (a connector in the person's mcp.json) is one row.
        public var id: String { MessagesList.key(item.conversation) }
        public var isUnread: Bool { (item.conversation.unread ?? 0) > 0 }
    }

    public static func key(_ c: DaemonAPI.MessagingConversation) -> String { c.source + ":" + c.id }

    /// An RFC 3339 time, with or without fractions of a second.
    public static func date(_ text: String) -> Date? {
        if let d = try? Date(text, strategy: .iso8601) { return d }
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// The machines' conversations in one list, each conversation once (the first machine's: this
    /// Mac comes first), the newest first; one with no time goes last. `source` keeps one service's.
    public static func merged(_ lists: [HostConversations], source: String = "") -> [Row] {
        var seen = Set<String>()
        var rows: [Row] = []
        for list in lists {
            for item in list.conversations where source.isEmpty || item.conversation.source == source {
                let row = Row(host: list.host, item: item)
                if seen.insert(row.id).inserted { rows.append(row) }
            }
        }
        return rows.enumerated().sorted { a, b in
            switch (a.element.conversation.lastActivityDate, b.element.conversation.lastActivityDate) {
            case let (x?, y?) where x != y: x > y
            case (.some, nil): true
            case (nil, .some): false
            default: a.offset < b.offset
            }
        }.map(\.element)
    }

    /// The services the lists have, for the Source filter, by name.
    public static func sources(_ lists: [HostConversations]) -> [String] {
        Set(lists.flatMap { $0.conversations.map(\.conversation.source) })
            .sorted { ChannelLinkWords.channel($0) < ChannelLinkWords.channel($1) }
    }

    /// The lines that say what could not be read: a machine, or a connector on one.
    public static func problems(_ lists: [HostConversations]) -> [String] {
        lists.flatMap { list -> [String] in
            if let problem = list.problem { return ["\(list.name): \(problem)"] }
            return list.errors.map { "\(list.name) ▸ \($0.server): \($0.message)" }
        }
    }

    /// No machine has a messaging connector that follows the contract: no conversation and no error.
    public static func noConnector(_ lists: [HostConversations]) -> Bool {
        lists.allSatisfy { $0.conversations.isEmpty && $0.errors.isEmpty && $0.problem == nil }
    }

    public static let title = "Messages"
    public static let sidebarHelp = "Your messaging connectors' conversations"
    public static let noMachine = "No machine reads messages yet. Update Agents on a machine to read its messaging connectors."
    public static let noConnector = "No messaging connector yet. Add Slack, Email, Google Chat or WhatsApp in a folder's Connectors ▸ Messaging."
    public static let setUp = "Open Connectors"
    public static let noConversations = "No conversations."
    public static let noUnread = "No unread conversations."
    public static let noMessages = "No messages."
    public static let outside = "Outside content: these messages come from other people, through the connector."

    public static let reply = "Reply"
    public static let send = "Send"
    public static let sending = "Sending…"
    public static let replyPlaceholder = "Write a reply"
    public static let replyInThread = "Reply in thread"
    public static let inThread = "In a thread"
    public static let leaveThread = "Not in the thread"

    /// Who the reply goes as, under the field: "Sent as the Slack bot @agents, not as an agent."
    public static func sentAs(_ replyAs: String) -> String { "Sent as \(replyAs), not as an agent." }

    /// The text of a reply to send: trimmed, or nil when there is none.
    public static func replyText(_ draft: String) -> String? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// "3 unread", or nil.
    public static func unread(_ c: DaemonAPI.MessagingConversation) -> String? {
        guard let n = c.unread, n > 0 else { return nil }
        return "\(n) unread"
    }

    /// The sender as people say it: a name, else the handle or address.
    public static func sender(_ s: DaemonAPI.ChannelSender) -> String {
        if let name = s.name, !name.isEmpty { return name }
        return s.identity
    }

    // MARK: The sidebar row's grey line (#4934)

    /// The event a messaging connector raises for a message (Slack, Google Chat, WhatsApp).
    public static let receivedEvent = "message.received"

    /// The newest `message.received` and what came of it, for the row's line.
    public struct LastConsequence: Sendable, Hashable {
        public var at: Date
        /// "woke Fix login bug", "started triage", or "nothing woke".
        public var words: String

        public init(at: Date, words: String) {
            self.at = at
            self.words = words
        }
    }

    /// The newest `message.received` in `events` (every machine's, in any order) and what it did: the session it
    /// woke, else the workflow it started, else "nothing woke", which is the case a person looks into. Nil when
    /// there is none.
    public static func lastConsequence(_ events: [Event]) -> LastConsequence? {
        guard let newest = events.filter({ $0.name == receivedEvent }).max(by: { $0.latest < $1.latest }) else { return nil }
        var words = "nothing woke"
        for consequence in newest.consequences {
            if case .woke(_, let title) = consequence { words = "woke \(title)"; break }
            if case .fired(let workflow, _, _) = consequence, words == "nothing woke" { words = "started \(workflow)" }
        }
        return LastConsequence(at: newest.latest, words: words)
    }

    /// The unread messages of every machine's conversations, each conversation once; nil when no conversation
    /// gives a count, so the line leaves it out.
    public static func unreadTotal(_ lists: [HostConversations]) -> Int? {
        let counts = merged(lists).compactMap(\.conversation.unread)
        return counts.isEmpty ? nil : counts.reduce(0, +)
    }

    /// The Messages row's grey line: "12 unread · woke Fix login bug 4 min ago". A count of 0 or none is left out;
    /// nil when there is nothing to say, so the row has no line.
    public static func statusLine(unread: Int?, last: LastConsequence?, now: Date = Date()) -> String? {
        var parts: [String] = []
        if let unread, unread > 0 { parts.append("\(unread) unread") }
        if let last { parts.append("\(last.words) \(StatusSecretsWords.ago(last.at, now: now))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// An SF Symbol for a service.
    public static func symbol(_ source: String) -> String {
        switch source {
        case "slack": "number"
        case "email": "envelope"
        case "googlechat": "bubble.left.and.text.bubble.right"
        case "whatsapp": "phone.bubble"
        case "discord", "teams": "bubble.left.and.bubble.right"
        default: "bubble.left"
        }
    }
}
