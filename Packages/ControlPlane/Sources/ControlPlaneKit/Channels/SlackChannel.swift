import AgentsKitCore
import Foundation

/// Slack as a channel (#1009): Socket Mode, so the control plane dials out and needs no
/// public address or relay.
///
/// - Out: a direct message to the tied member, the question with its options as buttons.
/// - In: a button pressed, or a reply in the message's thread, by that member only.
///
/// The app token (`xapp-`, `connections:write`) opens the socket; the bot token (`xoxb-`,
/// `chat:write`, `im:write`, `im:history`) sends and changes messages. Neither is ever logged.
public final class SlackChannel: NeedsChannel, @unchecked Sendable {
    public struct Tokens: Sendable {
        public var app: String
        public var bot: String
        public init(app: String, bot: String) {
            self.app = app
            self.bot = bot
        }
    }

    /// Where a sent question is in Slack.
    struct Posted: Sendable, Equatable {
        var channel: String
        var ts: String
        var message: NeedMessage
    }

    private let tokens: Tokens
    private let memberID: String
    private let transport: any SlackTransport
    private let retry: @Sendable (Int) -> Duration
    private let log: @Sendable (String) -> Void

    private let lock = NSLock()
    private var posted: [String: Posted] = [:]
    private var dm: String?
    private var runner: Task<Void, Never>?
    private var socket: (any LineTransport)?

    public init(tokens: Tokens, memberID: String, transport: any SlackTransport = SlackHTTP(),
                retry: @escaping @Sendable (Int) -> Duration = SlackChannel.backoff,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.tokens = tokens
        self.memberID = memberID
        self.transport = transport
        self.retry = retry
        self.log = log
    }

    /// 2, 4, 8 … seconds, at most two minutes.
    public static let backoff: @Sendable (Int) -> Duration = { attempt in
        .seconds(min(120, 1 << min(attempt + 1, 7)))
    }

    // MARK: Connecting

    public func start(heard: @escaping @Sendable (ChannelReply) async -> Void,
                      status: @escaping @Sendable (ChannelStatus) async -> Void) async {
        let runner = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled, let self {
                await status(.connecting)
                do {
                    let url = try await self.socketURL()
                    let socket = try await self.transport.connect(url)
                    self.lock.withLock { self.socket = socket }
                    attempt = try await self.read(socket, heard: heard, status: status) ? 0 : attempt
                } catch {
                    if Task.isCancelled { break }
                    await status(.failed(Self.words(for: error)))
                    self.log("slack: \(Self.words(for: error))")
                }
                self.lock.withLock { self.socket = nil }
                if Task.isCancelled { break }
                try? await Task.sleep(for: self.retry(attempt))
                attempt += 1
            }
        }
        lock.withLock { self.runner = runner }
    }

    public func stop() async {
        let (runner, socket) = lock.withLock { (self.runner, self.socket) }
        runner?.cancel()
        socket?.close()
    }

    /// `apps.connections.open`: a WebSocket address for this connection, good once.
    func socketURL() async throws -> URL {
        let reply = try await transport.call("apps.connections.open", token: tokens.app, body: [:])
        guard let text = reply["url"]?.stringValue, let url = URL(string: text) else {
            throw SlackFailure("Slack gave no address to connect to.")
        }
        return url
    }

    /// Reads envelopes until Slack says to go or the socket closes. True when it was
    /// connected, so the next try comes soon.
    private func read(_ socket: any LineTransport, heard: @escaping @Sendable (ChannelReply) async -> Void,
                      status: @escaping @Sendable (ChannelStatus) async -> Void) async throws -> Bool {
        var connected = false
        var partial = ""
        for try await line in socket.lines() {
            partial += partial.isEmpty ? line : "\n" + line
            guard let envelope = try? JSONDecoder().decode(JSONValue.self, from: Data(partial.utf8)) else {
                // A frame cut at a newline; given up past a size no envelope reaches.
                if partial.utf8.count > 1 << 20 { partial = "" }
                continue
            }
            partial = ""
            // Every envelope is acknowledged at once, or Slack sends it again.
            if let id = envelope["envelope_id"]?.stringValue,
               let ack = try? JSONValue.object(["envelope_id": .string(id)]).line() {
                try? socket.write(line: ack)
            }
            switch envelope["type"]?.stringValue {
            case "hello":
                connected = true
                await status(.connected)
                log("slack: connected")
            case "disconnect":
                // Slack moves connections now and then; it says so first.
                socket.close()
                return connected
            case "interactive":
                if let reply = reply(toAction: envelope["payload"]) { await heard(reply) }
            case "events_api":
                if let reply = reply(toEvent: envelope["payload"]?["event"]) { await heard(reply) }
            default:
                break
            }
        }
        return connected
    }

    /// A button: its block names the question, its value the option.
    func reply(toAction payload: JSONValue?) -> ChannelReply? {
        guard let payload, payload["type"]?.stringValue == "block_actions",
              payload["user"]?["id"]?.stringValue == memberID,
              let action = payload["actions"]?.arrayValue?.first,
              let key = action["block_id"]?.stringValue, let value = action["value"]?.stringValue,
              lock.withLock({ posted[key] }) != nil else { return nil }
        return .picked(key: key, value: value)
    }

    /// A message in a question's thread, in the direct messages, from the tied member.
    func reply(toEvent event: JSONValue?) -> ChannelReply? {
        guard let event, event["type"]?.stringValue == "message", event["subtype"] == nil, event["bot_id"] == nil,
              event["user"]?.stringValue == memberID,
              let thread = event["thread_ts"]?.stringValue, let text = event["text"]?.stringValue,
              let channel = event["channel"]?.stringValue else { return nil }
        let key = lock.withLock { posted.first { $0.value.channel == channel && $0.value.ts == thread }?.key }
        return key.map { .wrote(key: $0, text: text) }
    }

    // MARK: Sending

    public func send(_ message: NeedMessage) async throws {
        let channel = try await directMessages()
        let reply = try await transport.call("chat.postMessage", token: tokens.bot, body: [
            "channel": .string(channel),
            "text": .string(Self.fallback(message)),
            "blocks": Self.blocks(message, closing: nil),
        ])
        guard let ts = reply["ts"]?.stringValue else { throw SlackFailure("Slack didn't say where the message went.") }
        lock.withLock { posted[message.key] = Posted(channel: channel, ts: ts, message: message) }
    }

    public func close(_ key: String, saying: String) async {
        guard let sent = lock.withLock({ posted.removeValue(forKey: key) }) else { return }
        do {
            _ = try await transport.call("chat.update", token: tokens.bot, body: [
                "channel": .string(sent.channel), "ts": .string(sent.ts),
                "text": .string("\(Self.fallback(sent.message)) — \(saying)"),
                "blocks": Self.blocks(sent.message, closing: saying),
            ])
        } catch {
            log("slack: could not close a question: \(Self.words(for: error))")
        }
    }

    public func note(_ key: String, _ text: String) async {
        guard let sent = lock.withLock({ posted[key] }) else { return }
        do {
            _ = try await transport.call("chat.postMessage", token: tokens.bot, body: [
                "channel": .string(sent.channel), "thread_ts": .string(sent.ts), "text": .string(text),
            ])
        } catch {
            log("slack: could not reply in a thread: \(Self.words(for: error))")
        }
    }

    /// The direct messages with the tied member, opened once.
    private func directMessages() async throws -> String {
        if let dm = lock.withLock({ dm }) { return dm }
        let reply = try await transport.call("conversations.open", token: tokens.bot, body: ["users": .string(memberID)])
        guard let id = reply["channel"]?["id"]?.stringValue else {
            throw SlackFailure("Slack wouldn't open direct messages with \(memberID).")
        }
        lock.withLock { dm = id }
        return id
    }

    // MARK: Drawing

    static func fallback(_ message: NeedMessage) -> String {
        "\(message.heading.isEmpty ? "An agent" : message.heading) needs you: \(message.question)"
    }

    /// The question's blocks; with `closing`, without its buttons and with why it closed.
    /// The actions block's id is the question's key, so a press says which question it was.
    static func blocks(_ message: NeedMessage, closing: String?) -> JSONValue {
        var blocks: [JSONValue] = []
        if !message.heading.isEmpty {
            blocks.append(["type": "context", "elements": [["type": "mrkdwn", "text": .string(escape(message.heading))]]])
        }
        var text = "*\(escape(message.question))*"
        if let detail = message.detail, !detail.isEmpty { text += "\n\(escape(detail))" }
        blocks.append(["type": "section", "text": ["type": "mrkdwn", "text": .string(String(text.prefix(3000)))]])
        if let closing {
            blocks.append(["type": "context", "elements": [["type": "mrkdwn", "text": .string(escape(closing))]]])
            return .array(blocks)
        }
        if !message.options.isEmpty {
            let buttons: [JSONValue] = message.options.prefix(25).enumerated().map { index, option in
                ["type": "button", "action_id": .string("option-\(index)"),
                 "text": ["type": "plain_text", "text": .string(String(option.title.prefix(75))), "emoji": true],
                 "value": .string(String(option.value.prefix(2000)))]
            }
            blocks.append(["type": "actions", "block_id": .string(message.key), "elements": .array(buttons)])
        }
        let hint = message.answerElsewhere ? "Answer this one in Agents."
            : message.options.isEmpty ? "Reply in this thread to answer."
            : message.takesText ? "Press one, or reply in this thread." : "Press one."
        blocks.append(["type": "context", "elements": [["type": "mrkdwn", "text": .string(hint)]]])
        return .array(blocks)
    }

    /// Slack's three characters with a meaning of their own in text.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func words(for error: any Error) -> String {
        (error as? SlackFailure)?.description ?? "\(error)"
    }
}

/// Something Slack refused, in words a person can act on.
public struct SlackFailure: Error, CustomStringConvertible, Sendable, Equatable {
    public var description: String
    public init(_ description: String) { self.description = description }

    /// Slack's `error` code, said so a person knows what to fix.
    static func said(_ code: String, method: String) -> SlackFailure {
        switch code {
        case "invalid_auth", "not_authed", "account_inactive", "token_revoked":
            SlackFailure("Slack refused the token for \(method) (\(code)). Check the app and bot tokens.")
        case "missing_scope":
            SlackFailure("The Slack app lacks a scope \(method) needs. Add the scopes in the set-up steps and reinstall it.")
        case "user_not_found", "users_not_found":
            SlackFailure("Slack knows no member with that ID in this workspace.")
        default:
            SlackFailure("Slack refused \(method): \(code).")
        }
    }
}

/// How the channel reaches Slack: the Web API and a Socket Mode WebSocket. Tests give it a
/// fake Slack.
public protocol SlackTransport: Sendable {
    /// `https://slack.com/api/<method>` with a token; the reply when `ok`, else a `SlackFailure`.
    func call(_ method: String, token: String, body: [String: JSONValue]) async throws -> JSONValue
    func connect(_ url: URL) async throws -> any LineTransport
}

extension JSONValue {
    /// One line of JSON.
    func line() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
}
