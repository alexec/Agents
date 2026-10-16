import AgentsKitCore
import Foundation

/// Between the hosts' needs and a channel (#1012): a waiting question a host offers goes
/// out, and what the person says back answers it on that host.
///
/// Only question cards (Alex, 2026-10-15): a need that is an elicitation. Permissions,
/// reports and guarded changes are not sent. A host offers a need only when the person is
/// not at the Mac and not watching that conversation, as for a phone's notice, and withdraws
/// it when that changes or it is answered.
public actor ChannelDesk {
    public struct Hooks: Sendable {
        /// `elicitations/pending` on a host.
        public var pending: @Sendable (HostID) async throws -> [ElicitationRequest]
        /// `elicitations/answer` on a host.
        public var answer: @Sendable (HostID, DaemonAPI.AnswerElicitationRequest) async throws -> Void

        public init(pending: @escaping @Sendable (HostID) async throws -> [ElicitationRequest],
                    answer: @escaping @Sendable (HostID, DaemonAPI.AnswerElicitationRequest) async throws -> Void) {
            self.pending = pending
            self.answer = answer
        }
    }

    /// How a question is answered from a channel.
    enum Shape: Sendable, Equatable {
        /// One choice, perhaps with a note beside it (`question_0` and `question_0_custom`).
        case choice(property: String, choices: [ElicitationSchema.Property.Choice], note: String?)
        case text(property: String)
        case boolean(property: String)
        /// Only in Agents.
        case elsewhere
    }

    struct Open: Sendable {
        var host: HostID
        var request: UUID
        var shape: Shape
        /// Words written before a button was pressed, for the note beside the choice.
        var note: String?
    }

    private let hooks: Hooks
    private var channel: (any NeedsChannel)?
    private var open: [String: Open] = [:]
    private let log: @Sendable (String) -> Void
    private let inbox: AsyncStream<(HostID, DaemonAPI.AttentionNeed)>.Continuation

    public init(hooks: Hooks, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.hooks = hooks
        self.log = log
        let (needs, inbox) = AsyncStream.makeStream(of: (HostID, DaemonAPI.AttentionNeed).self)
        self.inbox = inbox
        Task { [weak self] in
            for await (host, need) in needs { await self?.heard(host, need) }
        }
    }

    deinit { inbox.finish() }

    /// A host's `attention/need`, taken in the order heard and handled apart from the host's
    /// uplink: reading the question asks that host, whose reply comes up the same uplink.
    public nonisolated func post(_ host: HostID, _ need: DaemonAPI.AttentionNeed) {
        inbox.yield((host, need))
    }

    /// The channel questions go to from now on, or nil for none. What was open on the old
    /// one is forgotten: its buttons answer nothing.
    public func use(_ channel: (any NeedsChannel)?) {
        self.channel = channel
        open = [:]
    }

    static func key(_ host: HostID, _ need: NeedID) -> String { "\(host.rawValue)|\(need.token)" }

    /// A host's `attention/need`.
    public func heard(_ host: HostID, _ need: DaemonAPI.AttentionNeed) async {
        if let withdrawn = need.withdraw {
            let key = Self.key(host, withdrawn)
            guard open.removeValue(forKey: key) != nil else { return }
            await channel?.close(key, saying: "No longer waiting: answered, or seen in Agents.")
            return
        }
        guard let channel, let offered = need.need, case .elicitation(let id) = offered.id else { return }
        let key = Self.key(host, offered.id)
        // A host whose uplink came back offers every live need again.
        guard open[key] == nil else { return }
        let request: ElicitationRequest
        do {
            guard let found = try await hooks.pending(host).first(where: { $0.id == id }) else {
                log("channels: \(key) was answered before it could be sent")
                return
            }
            request = found
        } catch {
            log("channels: could not read \(host)'s question: \(error)")
            return
        }
        // Asked again while that was read.
        guard open[key] == nil else { return }
        let (message, shape) = Self.message(key: key, request: request, headline: offered.headline)
        open[key] = Open(host: host, request: id, shape: shape)
        do {
            try await channel.send(message)
            log("channels: sent \(key)")
        } catch {
            open[key] = nil
            log("channels: could not send \(key): \(error)")
        }
    }

    /// The question as a channel draws it, and how it is answered.
    static func message(key: String, request: ElicitationRequest, headline: Headline) -> (NeedMessage, Shape) {
        let heading = [headline.h1, headline.h2].filter { !$0.isEmpty }.joined(separator: " · ")
        guard case .form(let schema) = request.mode, schema.pages.count == 1, let first = schema.properties.first else {
            return (NeedMessage(key: key, heading: heading, question: request.message ?? request.title,
                                takesText: false, answerElsewhere: true), .elsewhere)
        }
        let question = request.message ?? first.title ?? schema.title ?? "The agent asks"
        let detail = first.description ?? (first.title != question ? first.title : nil)
        let note = schema.properties.dropFirst().first?.name
        switch first.kind {
        case .string(_, _, _, let choices?) where !choices.isEmpty:
            return (NeedMessage(key: key, heading: heading, question: question, detail: detail,
                                options: choices.map { .init(value: $0.value, title: $0.title) }),
                    .choice(property: first.name, choices: choices, note: note))
        case .string where note == nil:
            return (NeedMessage(key: key, heading: heading, question: question, detail: detail),
                    .text(property: first.name))
        case .boolean where note == nil:
            return (NeedMessage(key: key, heading: heading, question: question, detail: detail,
                                options: [.init(value: "true", title: "Yes"), .init(value: "false", title: "No")]),
                    .boolean(property: first.name))
        default:
            return (NeedMessage(key: key, heading: heading, question: question, detail: detail,
                                takesText: false, answerElsewhere: true), .elsewhere)
        }
    }

    /// The tied person said something to a question.
    public func heard(_ reply: ChannelReply) async {
        guard let channel, var question = open[reply.key] else { return }
        var content: [String: JSONValue] = [:]
        var said = ""
        switch (question.shape, reply) {
        case (.choice(let property, let choices, let note), .picked(_, let value)):
            guard let choice = choices.first(where: { $0.value == value }) else { return }
            content[property] = .string(value)
            if let note, let words = question.note { content[note] = .string(words) }
            said = choice.title
        case (.choice(let property, let choices, let note), .wrote(_, let text)):
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let choice = choices.first(where: { Self.same($0.title, words) || Self.same($0.value, words) }) {
                content[property] = .string(choice.value)
                said = choice.title
            } else if note != nil {
                question.note = words
                open[reply.key] = question
                await channel.note(reply.key, "Noted. Now pick one of the buttons, and your words go with it.")
                return
            } else {
                await channel.note(reply.key, "Pick one of the buttons.")
                return
            }
        case (.text(let property), .wrote(_, let text)):
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { return }
            content[property] = .string(words)
            said = words
        case (.boolean(let property), .picked(_, let value)):
            content[property] = .bool(value == "true")
            said = value == "true" ? "Yes" : "No"
        case (.boolean(let property), .wrote(_, let text)):
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.same(words, "yes") || Self.same(words, "y") {
                content[property] = .bool(true)
                said = "Yes"
            } else if Self.same(words, "no") || Self.same(words, "n") {
                content[property] = .bool(false)
                said = "No"
            } else {
                await channel.note(reply.key, "Say yes or no, or press a button.")
                return
            }
        case (.elsewhere, _):
            await channel.note(reply.key, "This one can only be answered in Agents.")
            return
        default:
            return
        }
        do {
            try await hooks.answer(question.host, .init(requestID: question.request, action: .accept, content: content,
                                                        sendID: UUID()))
        } catch let error as JSONRPCError {
            await channel.note(reply.key, "That didn't go: \(error.message)")
            return
        } catch {
            await channel.note(reply.key, "That didn't go: the host didn't answer. Try again, or answer in Agents.")
            return
        }
        open[reply.key] = nil
        await channel.close(reply.key, saying: "Answered: \(said)")
        log("channels: answered \(reply.key)")
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// The questions out now, for tests.
    var openKeys: Set<String> { Set(open.keys) }
}
