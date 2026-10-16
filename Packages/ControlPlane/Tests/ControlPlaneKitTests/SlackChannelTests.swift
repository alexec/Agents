import AgentsKit
import AgentsKitCore
@testable import ControlPlaneKit
import Foundation
import Testing

/// Slack as the first channel (#1009, #1012): the adapter against a fake Slack, the desk
/// between needs and a channel, and the round trip through a control plane and a host.
@Suite("Slack answers Needs You", .serialized, .timeLimit(.minutes(2)))
struct SlackChannelTests {
    static let member = "U0ALEX"
    let message = NeedMessage(key: "h1|elicitation:A", heading: "work · Fix the test", question: "Tea or coffee?",
                              options: [.init(value: "tea", title: "Tea"), .init(value: "coffee", title: "Coffee")])

    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [ChannelReply] = []
        private var statuses: [ChannelStatus] = []
        var all: [ChannelReply] { lock.withLock { replies } }
        var status: ChannelStatus? { lock.withLock { statuses.last } }
        func add(_ reply: ChannelReply) { lock.withLock { replies.append(reply) } }
        func add(_ status: ChannelStatus) { lock.withLock { statuses.append(status) } }
    }

    func connected(_ slack: FakeSlack) async -> (SlackChannel, Heard) {
        let channel = SlackChannel(tokens: .init(app: "xapp-1", bot: "xoxb-1"), memberID: Self.member, transport: slack,
                                   retry: { _ in .milliseconds(10) })
        let heard = Heard()
        await channel.start(heard: { heard.add($0) }, status: { heard.add($0) })
        await eventually { heard.status == .connected }
        return (channel, heard)
    }

    // MARK: The adapter

    @Test func aQuestionGoesToTheMembersDirectMessagesWithItsOptionsAsButtons() async throws {
        let slack = FakeSlack()
        let (channel, _) = await connected(slack)
        defer { Task { await channel.stop() } }
        try await channel.send(message)

        #expect(slack.made("apps.connections.open").first?.token == "xapp-1")
        let open = try #require(slack.made("conversations.open").first)
        #expect(open.body["users"] == .string(Self.member))
        #expect(open.token == "xoxb-1")
        let post = try #require(slack.made("chat.postMessage").first)
        #expect(post.body["channel"] == "D1")
        #expect(post.body["text"]?.stringValue?.contains("Tea or coffee?") == true)
        let actions = try #require(post.body["blocks"]?.arrayValue?.first { $0["type"] == "actions" })
        #expect(actions["block_id"] == .string(message.key))
        #expect(actions["elements"]?.arrayValue?.compactMap { $0["value"]?.stringValue } == ["tea", "coffee"])
        #expect(actions["elements"]?.arrayValue?.first?["text"]?["text"] == "Tea")
    }

    @Test func onlyTheTiedMembersButtonIsHeardAndEveryEnvelopeIsAcknowledged() async throws {
        let slack = FakeSlack()
        let (channel, heard) = await connected(slack)
        defer { Task { await channel.stop() } }
        try await channel.send(message)

        slack.press("coffee", in: message.key, by: "U0SOMEONE")
        slack.press("tea", in: "h1|elicitation:NOT-SENT", by: Self.member)
        slack.press("tea", in: message.key, by: Self.member)
        await eventually { heard.all == [.picked(key: message.key, value: "tea")] }
        await eventually { slack.socket?.acks.count == 3 }
        #expect(heard.all.count == 1)
    }

    @Test func aReplyInTheQuestionsThreadIsHeardAndNothingElseIs() async throws {
        let slack = FakeSlack()
        let (channel, heard) = await connected(slack)
        defer { Task { await channel.stop() } }
        try await channel.send(message)
        let ts = try #require(slack.lastTS)

        slack.reply("not in a thread", inThread: nil, by: Self.member)
        slack.reply("someone else", inThread: ts, by: "U0SOMEONE")
        slack.reply("the bot itself", inThread: ts, by: Self.member, bot: true)
        slack.reply("another thread", inThread: "1.2", by: Self.member)
        slack.reply("Coffee, please", inThread: ts, by: Self.member)
        await eventually { heard.all == [.wrote(key: message.key, text: "Coffee, please")] }
        await eventually { slack.socket?.acks.count == 5 }
        #expect(heard.all.count == 1)
    }

    @Test func aClosedQuestionLosesItsButtonsAndSaysWhy() async throws {
        let slack = FakeSlack()
        let (channel, heard) = await connected(slack)
        defer { Task { await channel.stop() } }
        try await channel.send(message)
        await channel.note(message.key, "Pick one of the buttons.")
        await channel.close(message.key, saying: "Answered: Tea")

        let note = try #require(slack.made("chat.postMessage").last)
        #expect(note.body["thread_ts"] == .string(try #require(slack.lastTS)))
        let update = try #require(slack.made("chat.update").first)
        #expect(update.body["ts"] == .string(try #require(slack.lastTS)))
        let blocks = try #require(update.body["blocks"]?.arrayValue)
        #expect(!blocks.contains { $0["type"] == "actions" })
        #expect(blocks.last?["elements"]?.arrayValue?.first?["text"] == "Answered: Tea")
        // Closed: a late press answers nothing.
        slack.press("tea", in: message.key, by: Self.member)
        await eventually { slack.socket?.acks.count == 1 }
        #expect(heard.all.isEmpty)
    }

    @Test func itConnectsAgainWhenSlackSaysToGo() async throws {
        let slack = FakeSlack()
        let (channel, heard) = await connected(slack)
        defer { Task { await channel.stop() } }
        slack.socket?.push(["type": "disconnect", "reason": "refresh_requested"])
        await eventually { slack.connections == 2 && heard.status == .connected }
        #expect(slack.made("apps.connections.open").count == 2)
    }

    @Test func aRefusedTokenIsSaidInWords() async throws {
        let slack = FakeSlack()
        slack.refuse["apps.connections.open"] = "invalid_auth"
        let channel = SlackChannel(tokens: .init(app: "xapp-1", bot: "xoxb-1"), memberID: Self.member, transport: slack,
                                   retry: { _ in .seconds(60) })
        let heard = Heard()
        await channel.start(heard: { heard.add($0) }, status: { heard.add($0) })
        defer { Task { await channel.stop() } }
        await eventually {
            if case .failed(let words)? = heard.status { return words.contains("Check the app and bot tokens") }
            return false
        }
    }

    // MARK: The desk

    final class FakeChannel: NeedsChannel, @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [NeedMessage] = []
        private var _closed: [String: String] = [:]
        private var _notes: [String] = []
        var sent: [NeedMessage] { lock.withLock { _sent } }
        var closed: [String: String] { lock.withLock { _closed } }
        var notes: [String] { lock.withLock { _notes } }
        func start(heard: @escaping @Sendable (ChannelReply) async -> Void,
                   status: @escaping @Sendable (ChannelStatus) async -> Void) async {}
        func stop() async {}
        func send(_ message: NeedMessage) async throws { lock.withLock { _sent.append(message) } }
        func close(_ key: String, saying: String) async { lock.withLock { _closed[key] = saying } }
        func note(_ key: String, _ text: String) async { lock.withLock { _notes.append(text) } }
    }

    final class FakeHost: @unchecked Sendable {
        private let lock = NSLock()
        var pending: [ElicitationRequest]
        private var _answers: [DaemonAPI.AnswerElicitationRequest] = []
        var answers: [DaemonAPI.AnswerElicitationRequest] { lock.withLock { _answers } }
        var refuse: JSONRPCError?
        init(_ pending: [ElicitationRequest]) { self.pending = pending }
        func answer(_ answer: DaemonAPI.AnswerElicitationRequest) throws {
            if let refuse { throw refuse }
            lock.withLock { _answers.append(answer) }
        }
        var hooks: ChannelDesk.Hooks {
            .init(pending: { _ in self.pending }, answer: { _, answer in try self.answer(answer) })
        }
    }

    static func form(_ properties: [ElicitationSchema.Property], message: String? = "Tea or coffee?") -> ElicitationRequest {
        ElicitationRequest(agentID: UUID(), message: message, mode: .form(ElicitationSchema(properties: properties)))
    }

    static let drink = ElicitationSchema.Property(
        name: "drink", title: "Tea or coffee?", isRequired: true,
        kind: .string(format: nil, minLength: nil, maxLength: nil,
                      choices: [.init(value: "tea", title: "Tea"), .init(value: "coffee", title: "Coffee")]))

    static func offer(_ request: ElicitationRequest) -> DaemonAPI.AttentionNeed {
        .offer(Need(id: .elicitation(request.id), agentID: request.agentID, folder: URL(filePath: "/work"),
                    kind: .elicitation, raisedAt: Date(),
                    headline: Headline(h1: "work", h2: "Fix the test", h3: "Asks: Tea or coffee?")), buzz: true)
    }

    @Test func aWaitingQuestionGoesOutAndAButtonAnswersItOnItsHost() async throws {
        let request = Self.form([Self.drink])
        let host = FakeHost([request])
        let desk = ChannelDesk(hooks: host.hooks)
        let channel = FakeChannel()
        await desk.use(channel)

        await desk.heard(HostID(rawValue: "h1"), Self.offer(request))
        await desk.heard(HostID(rawValue: "h1"), Self.offer(request))
        let sent = try #require(channel.sent.first)
        #expect(channel.sent.count == 1)
        #expect(sent.heading == "work · Fix the test")
        #expect(sent.question == "Tea or coffee?")
        #expect(sent.options.map(\.title) == ["Tea", "Coffee"])

        await desk.heard(.picked(key: sent.key, value: "coffee"))
        let answer = try #require(host.answers.first)
        #expect(answer.requestID == request.id)
        #expect(answer.action == .accept)
        #expect(answer.content == ["drink": "coffee"])
        #expect(channel.closed[sent.key] == "Answered: Coffee")
        // The host withdraws it next: nothing more is said.
        await desk.heard(HostID(rawValue: "h1"), .withdraw(.elicitation(request.id)))
        #expect(channel.closed.count == 1)
    }

    @Test func wordsBeforeAButtonGoWithItAsTheNote() async throws {
        let note = ElicitationSchema.Property(name: "drink_custom", title: "Anything else?", isRequired: false,
                                              kind: .string(format: nil, minLength: nil, maxLength: nil, choices: nil))
        let request = Self.form([Self.drink, note])
        let host = FakeHost([request])
        let desk = ChannelDesk(hooks: host.hooks)
        let channel = FakeChannel()
        await desk.use(channel)
        await desk.heard(HostID(rawValue: "h1"), Self.offer(request))
        let key = try #require(channel.sent.first?.key)

        await desk.heard(.wrote(key: key, text: "oat milk"))
        #expect(host.answers.isEmpty)
        await desk.heard(.picked(key: key, value: "tea"))
        #expect(host.answers.first?.content == ["drink": "tea", "drink_custom": "oat milk"])
    }

    @Test func aReplyNamingAnOptionPicksItAndFreeTextAnswersAQuestionInWords() async throws {
        let words = ElicitationSchema.Property(name: "why", title: "Why did it fail?", isRequired: true,
                                               kind: .string(format: nil, minLength: nil, maxLength: nil, choices: nil))
        let choice = Self.form([Self.drink]), open = Self.form([words], message: nil)
        let host = FakeHost([choice, open])
        let desk = ChannelDesk(hooks: host.hooks)
        let channel = FakeChannel()
        await desk.use(channel)
        await desk.heard(HostID(rawValue: "h1"), Self.offer(choice))
        await desk.heard(HostID(rawValue: "h1"), Self.offer(open))
        let (first, second) = (channel.sent[0], channel.sent[1])
        #expect(second.options.isEmpty && second.takesText)
        #expect(second.question == "Why did it fail?")

        await desk.heard(.wrote(key: first.key, text: "neither"))
        #expect(channel.notes == ["Pick one of the buttons."])
        await desk.heard(.wrote(key: first.key, text: "  TEA "))
        await desk.heard(.wrote(key: second.key, text: "The disk was full."))
        #expect(host.answers.map(\.content) == [["drink": "tea"], ["why": "The disk was full."]])
    }

    @Test func aFormSlackCannotDrawSaysToAnswerInAgents() async throws {
        let other = ElicitationSchema.Property(name: "size", title: "Size?", isRequired: true,
                                               kind: .integer(minimum: 1, maximum: 3))
        let request = Self.form([Self.drink, other], message: "Two things")
        let host = FakeHost([request])
        let desk = ChannelDesk(hooks: host.hooks)
        let channel = FakeChannel()
        await desk.use(channel)
        await desk.heard(HostID(rawValue: "h1"), Self.offer(request))
        let sent = try #require(channel.sent.first)
        #expect(sent.answerElsewhere && sent.options.isEmpty && !sent.takesText)
        await desk.heard(.wrote(key: sent.key, text: "tea"))
        #expect(channel.notes == ["This one can only be answered in Agents."])
        #expect(host.answers.isEmpty)
    }

    @Test func aWithdrawnQuestionClosesAndOtherNeedsAreNotSent() async throws {
        let request = Self.form([Self.drink])
        let desk = ChannelDesk(hooks: FakeHost([request]).hooks)
        let channel = FakeChannel()
        await desk.use(channel)
        let permission = Need(id: .permission(UUID()), agentID: UUID(), folder: URL(filePath: "/work"), kind: .permission,
                              raisedAt: Date(), headline: Headline(h1: "work", h2: "x", h3: "may run a command"))
        await desk.heard(HostID(rawValue: "h1"), .offer(permission, buzz: true))
        #expect(channel.sent.isEmpty)

        await desk.heard(HostID(rawValue: "h1"), Self.offer(request))
        let key = try #require(channel.sent.first?.key)
        await desk.heard(HostID(rawValue: "h1"), .withdraw(.elicitation(request.id)))
        #expect(channel.closed[key]?.hasPrefix("No longer waiting") == true)
        await desk.heard(.picked(key: key, value: "tea"))
        #expect(channel.closed.count == 1)
    }

    @Test func anAnswerTheHostRefusesIsSaidAndTheQuestionStaysOpen() async throws {
        let request = Self.form([Self.drink])
        let host = FakeHost([request])
        host.refuse = JSONRPCError(code: JSONRPCError.invalidParams, message: "That answer doesn’t fit.")
        let desk = ChannelDesk(hooks: host.hooks)
        let channel = FakeChannel()
        await desk.use(channel)
        await desk.heard(HostID(rawValue: "h1"), Self.offer(request))
        let key = try #require(channel.sent.first?.key)
        await desk.heard(.picked(key: key, value: "tea"))
        #expect(channel.notes == ["That didn't go: That answer doesn’t fit."])
        #expect(await desk.openKeys == [key])
    }

    // MARK: Through the control plane

    @Test func theRoundTripThroughAControlPlaneAndAHost() async throws {
        let base = ControlServiceTests()
        let slack = FakeSlack()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("secrets-\(UUID().uuidString)")
        @Sendable func url(_ port: Int) -> URL { URL(string: "http://127.0.0.1:\(port)")! }
        let (service, port) = try await ControlPlaneKitTests.started { port in
            var configuration = ControlService.Configuration(store: MemoryStore(), privateKey: base.control.privateKey,
                                                             url: url(port), bind: "127.0.0.1", port: port, name: "test",
                                                             machineID: "m")
            configuration.secretsHome = home
            configuration.slack = slack
            return try ControlService(configuration)
        }
        defer { Task { await service.stop() } }

        // A host holding one question, which records the answer it is given.
        let request = Self.form([Self.drink])
        let answered = FakeHost([request])
        let key = ControlAgreement.generate()
        let announced = try await base.use(try await service.codes.issue(.host).text, at: url(port),
                                           method: DaemonAPI.Method.hostsAnnounce, params: try JSONValue.encoding(
            DaemonAPI.HostAnnounce(publicKey: key.publicKey, name: "devbox", platform: "Linux arm64", version: "1",
                                   machineID: "linux-1")))
        let host = try #require(try announced.decode(DaemonAPI.Admitted.self).host)
        let server = DaemonServer(url: URL(fileURLWithPath: "/tmp/unused-\(UUID()).sock")) { _, method, params in
            switch method {
            case DaemonAPI.Method.elicitationsPending:
                return .success((try? JSONValue.encoding(answered.pending)) ?? [])
            case DaemonAPI.Method.elicitationsAnswer:
                guard let answer = try? params?.decode(DaemonAPI.AnswerElicitationRequest.self) else {
                    return .failure(JSONRPCError(code: JSONRPCError.invalidParams, message: "no"))
                }
                try? answered.answer(answer)
                return .success([:])
            default:
                return .failure(.methodNotFound(method))
            }
        }
        let hostKey = try ControlAuth.hostKey(privateKey: key.privateKey, peer: base.control.publicKey, host: host)
        let uplink = ControlUplink(server: server, hello: DaemonAPI.HostHello(host: host, version: "1", platform: "Linux arm64",
                                                                             machineID: "linux-1")) { [control = base.control] in
            try await base.join(url(port), .init(identity: .host(host), key: hostKey, kind: "host", controlKey: control.publicKey))
        }
        uplink.start()
        defer { uplink.stop() }
        await eventually { await service.router.state(of: host)?.isOnline == true }

        // Settings, from a paired client: a member ID refused, then everything set.
        let (_, link) = try await base.client(at: url(port), code: try await service.codes.issue(.client).text)
        defer { link.disconnect() }
        let control = DaemonClient(link: link.controlLink)
        try await control.connect(startIfNeeded: false)
        let off = try await control.call(DaemonAPI.Method.channelsGet, returning: DaemonAPI.ChannelsState.self)
        #expect(off.slack.status == DaemonAPI.SlackState.off && off.slack.available && !off.slack.appTokenSet)
        await #expect(throws: JSONRPCError.self) {
            _ = try await control.call(DaemonAPI.Method.channelsSet,
                                       try JSONValue.encoding(DaemonAPI.ChannelsSet(slack: .init(memberID: "alex"))))
        }
        let set = try await control.call(DaemonAPI.Method.channelsSet, try JSONValue.encoding(DaemonAPI.ChannelsSet(
            slack: .init(enabled: true, memberID: Self.member, appToken: "xapp-secret", botToken: "xoxb-secret"))),
                                         returning: DaemonAPI.ChannelsState.self)
        #expect(set.slack.enabled && set.slack.appTokenSet && set.slack.botTokenSet)
        // Written to the secrets folder only, 0600 in 0700, and never sent back.
        let file = home.appending(path: ".agents-secrets/channels.env")
        #expect(try String(contentsOf: file, encoding: .utf8).contains("SLACK_BOT_TOKEN=xoxb-secret"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let folderMode = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(folderMode == 0o700)
        let state = try await control.call(DaemonAPI.Method.channelsGet)
        #expect(!String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains("secret"))
        #expect(await service.methods.controlSettings.channels?.slack == SlackChannelSettings(enabled: true, memberID: Self.member))
        await eventually {
            (try? await control.call(DaemonAPI.Method.channelsGet, returning: DaemonAPI.ChannelsState.self))?.slack.status
                == DaemonAPI.SlackState.connected
        }
        #expect(slack.made("apps.connections.open").first?.token == "xapp-secret")

        // The host offers its question; Slack shows it; the member presses Tea.
        uplink.tell(DaemonAPI.Method.attentionNeed, try JSONValue.encoding(Self.offer(request)))
        await eventually { !slack.made("chat.postMessage").isEmpty }
        let posted = try #require(slack.made("chat.postMessage").first)
        let block = try #require(posted.body["blocks"]?.arrayValue?.first { $0["type"] == "actions" }?["block_id"]?.stringValue)
        slack.press("tea", in: block, by: Self.member)
        await eventually { !answered.answers.isEmpty }
        #expect(answered.answers.first?.requestID == request.id)
        #expect(answered.answers.first?.content == ["drink": "tea"])
        await eventually { !slack.made("chat.update").isEmpty }

        // Turned off, it stops.
        _ = try await control.call(DaemonAPI.Method.channelsSet,
                                   try JSONValue.encoding(DaemonAPI.ChannelsSet(slack: .init(enabled: false))))
        let stopped = try await control.call(DaemonAPI.Method.channelsGet, returning: DaemonAPI.ChannelsState.self)
        #expect(stopped.slack.status == DaemonAPI.SlackState.off)
    }
}
