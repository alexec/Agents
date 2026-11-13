import Foundation
import Testing
@testable import AgentsKitCore

/// The Messages page's list (#4344): the machines' conversations in one list, its reply (#4345), and its types on the wire.
@Suite("Messages list")
struct MessagesListTests {
    typealias Conversation = DaemonAPI.MessagingConversation

    static let mac = MachineRef.mac
    static let box = MachineRef(rawValue: "box")

    static func item(_ source: String, _ id: String, at: TimeInterval?, unread: Int? = nil) -> DaemonAPI.MessagesConversation {
        .init(server: source, folder: "/p",
              conversation: Conversation(source: source, id: id, title: id, kind: .channel, unread: unread,
                                         lastActivity: at.map { Date(timeIntervalSince1970: $0).ISO8601Format() }))
    }

    @Test func theMachinesMergeNewestFirstEachConversationOnce() {
        let lists: [MessagesList.HostConversations] = [
            .init(host: Self.mac, name: "This Mac", conversations: [Self.item("slack", "C1", at: 100), Self.item("email", "t1", at: nil)]),
            .init(host: Self.box, name: "Box", conversations: [Self.item("slack", "C1", at: 100), Self.item("slack", "C2", at: 300)]),
        ]
        let rows = MessagesList.merged(lists)
        #expect(rows.map(\.conversation.id) == ["C2", "C1", "t1"])
        // The first machine's copy: this Mac comes first.
        #expect(rows.first { $0.conversation.id == "C1" }?.host == Self.mac)
        #expect(MessagesList.merged(lists, source: "email").map(\.conversation.id) == ["t1"])
        #expect(MessagesList.sources(lists) == ["email", "slack"])
    }

    @Test func noConnectorIsNoConversationAndNoError() {
        #expect(MessagesList.noConnector([.init(host: Self.mac, name: "This Mac")]))
        let failed = MessagesList.HostConversations(host: Self.box, name: "Box",
                                                    errors: [.init(server: "slack", folder: "/p", message: "No token.")])
        #expect(!MessagesList.noConnector([failed]))
        #expect(MessagesList.problems([failed]) == ["Box ▸ slack: No token."])
        #expect(MessagesList.problems([.init(host: Self.mac, name: "This Mac", problem: "Offline.")]) == ["This Mac: Offline."])
    }

    @Test func timesAreRFC3339WithOrWithoutFractions() {
        #expect(MessagesList.date("2026-11-10T08:00:00Z") == Date(timeIntervalSince1970: 1_794_297_600))
        #expect(MessagesList.date("2026-11-10T08:00:00.5Z") == Date(timeIntervalSince1970: 1_794_297_600.5))
        #expect(MessagesList.date("yesterday") == nil)
    }

    @Test func theWordsOfARow() {
        #expect(MessagesList.unread(Self.item("slack", "C1", at: nil, unread: 3).conversation) == "3 unread")
        #expect(MessagesList.unread(Self.item("slack", "C1", at: nil, unread: 0).conversation) == nil)
        #expect(MessagesList.sender(.init(channel: "slack", identity: "U1", name: "Sam")) == "Sam")
        #expect(MessagesList.sender(.init(channel: "email", identity: "sam@example.com")) == "sam@example.com")
    }

    /// What the window reads and asks, written with today's encoder, fits the schema the Go host is made from.
    @Test func theTypesFitTheSchema() throws {
        let schema = try WireSchema(WireSchemaTests.read("daemon.schema.json"))
        let list = DaemonAPI.MessagesConversations(
            conversations: [.init(server: "slack", folder: "/p",
                                  conversation: .init(source: "slack", id: "C1", title: "#general", kind: .channel, unread: 2,
                                                      lastActivity: "2026-11-10T08:00:00Z",
                                                      sender: .init(channel: "slack", identity: "T1/U1", name: "Sam"),
                                                      link: "https://x.slack.com/archives/C1"),
                                  replyAs: "the Slack bot @agents")],
            cursor: "abc", errors: [.init(server: "mail", folder: "/p", message: "No answer.")])
        let read = DaemonAPI.MessagesRead(
            server: "slack", folder: "/p", conversation: "C1",
            messages: [.init(id: "1.2", conversation: "C1",
                             sender: .init(channel: "email", identity: "sam@example.com", name: "Sam", email: "sam@example.com",
                                           dkim: .init(result: "pass", domain: "example.com")),
                             time: "2026-11-10T08:00:00.123Z", text: "Hi", thread: "1.0", link: "https://x")],
            cursor: "older", untrusted: true)
        let listErrors = schema.errors(try JSONValue.encoding(list), against: "MessagesConversations")
        #expect(listErrors == [], "\(listErrors)")
        let readErrors = schema.errors(try JSONValue.encoding(read), against: "MessagesRead")
        #expect(readErrors == [], "\(readErrors)")
        #expect(schema.errors(try JSONValue.encoding(DaemonAPI.MessagesConversationsRequest(cursor: "c", limit: 50, unread: true)),
                              against: "MessagesConversationsRequest") == [])
        #expect(schema.errors(try JSONValue.encoding(DaemonAPI.MessagesReadRequest(server: "slack", folder: "/p", conversation: "C1",
                                                                                   cursor: "c", limit: 50)),
                              against: "MessagesReadRequest") == [])
        #expect(schema.errors(try JSONValue.encoding(DaemonAPI.MessagesReplyRequest(server: "slack", folder: "/p", conversation: "C1",
                                                                                    thread: "1.0", text: "On it.")),
                              against: "MessagesReplyRequest") == [])
        let replied = DaemonAPI.MessagesReplied(server: "slack", folder: "/p", conversation: "C1", message: try #require(read.messages.first))
        #expect(schema.errors(try JSONValue.encoding(replied), against: "MessagesReplied") == [])

        var marked = read
        marked.markedRead = true
        #expect(schema.errors(try JSONValue.encoding(marked), against: "MessagesRead") == [])
        #expect(schema.errors(try JSONValue.encoding(DaemonAPI.MessagesMarkAllReadRequest(folder: "/p")),
                              against: "MessagesMarkAllReadRequest") == [])
        let all = DaemonAPI.MessagesMarkedAllRead(marked: [.init(server: "email", folder: "/p", marked: 3)],
                                                  errors: [.init(server: "mail", folder: "/p", message: "No answer.")])
        #expect(schema.errors(try JSONValue.encoding(all), against: "MessagesMarkedAllRead") == [])
    }

    /// Next (#5137): the row after the open one, in the list as it is filtered now; none at the end.
    @Test func nextIsTheRowAfterInTheListAsItIsNow() {
        let lists: [MessagesList.HostConversations] = [
            .init(host: Self.mac, name: "This Mac", conversations: [Self.item("slack", "C1", at: 300), Self.item("email", "t1", at: 200),
                                                                     Self.item("slack", "C2", at: 100)]),
        ]
        let all = MessagesList.merged(lists)
        #expect(MessagesList.next(after: "slack:C1", in: all)?.conversation.id == "t1")
        #expect(MessagesList.next(after: "slack:C2", in: all) == nil)
        #expect(MessagesList.next(after: "slack:C1", in: MessagesList.merged(lists, source: "slack"))?.conversation.id == "C2")
        #expect(MessagesList.next(after: "slack:gone", in: all) == nil)
    }

    /// Marking read (#5137): one conversation on every machine that has it, or all; a count the service never gave
    /// stays absent.
    @Test func markedReadSetsTheCountToNought() {
        let lists: [MessagesList.HostConversations] = [
            .init(host: Self.mac, name: "This Mac", conversations: [Self.item("email", "t1", at: 2, unread: 2),
                                                                     Self.item("email", "t2", at: 1, unread: 1)]),
            .init(host: Self.box, name: "Box", conversations: [Self.item("email", "t1", at: 2, unread: 2),
                                                               Self.item("slack", "C1", at: 3)]),
        ]
        #expect(MessagesList.hasUnread(lists))
        let one = MessagesList.markedRead(lists, key: "email:t1")
        #expect(one.flatMap { $0.conversations.map(\.conversation.unread) } == [0, 1, 0, nil])
        #expect(MessagesList.unreadTotal(one) == 1)
        let all = MessagesList.markedRead(lists)
        #expect(MessagesList.unreadTotal(all) == 0)
        #expect(!MessagesList.hasUnread(all))
        #expect(MessagesList.markProblems([
            (name: "This Mac", marked: .init(errors: [.init(server: "mail", folder: "/p", message: "No answer.")]), problem: nil),
            (name: "Box", marked: nil, problem: "Offline."),
        ]) == ["This Mac ▸ mail: No answer.", "Box: Offline."])
    }

    /// The reply field (#4345): what it sends, and who it says the reply goes as.
    @Test func theWordsOfAReply() {
        #expect(MessagesList.replyText("  On it.\n") == "On it.")
        #expect(MessagesList.replyText(" \n ") == nil)
        #expect(MessagesList.sentAs("the Slack bot @agents") == "Sent as the Slack bot @agents, not as an agent.")
    }
    /// The sidebar Messages row's grey line (#4934): the unread count, and what the newest message woke.
    @Test func theRowsLineSaysTheUnreadAndWhatTheLastMessageWoke() {
        let now = Date(timeIntervalSince1970: 10_000)
        func event(_ position: EventPosition, _ name: String, at: TimeInterval, _ consequences: [Consequence] = []) -> Event {
            Event(position: position, name: name, at: Date(timeIntervalSince1970: at), scope: .mac, sentence: "",
                  consequences: consequences)
        }
        let agent = UUID()
        let folder = URL(fileURLWithPath: "/p")
        let woke = event(1, "message.received", at: 9_760, [.fired(workflowID: "triage", folder: folder, agentID: nil),
                                                             .woke(agentID: agent, title: "Fix login bug")])
        let last = MessagesList.lastConsequence([woke, event(2, "agent.started", at: 9_990)])
        #expect(last == .init(at: Date(timeIntervalSince1970: 9_760), words: "woke Fix login bug"))
        #expect(MessagesList.statusLine(unread: 12, last: last, now: now) == "12 unread · woke Fix login bug 4 min ago")
        // A workflow's start when it woke no session; nothing, the case to look into, said as such.
        let fired = event(3, "message.received", at: 9_000, [.fired(workflowID: "triage", folder: folder, agentID: agent)])
        #expect(MessagesList.lastConsequence([fired])?.words == "started triage")
        let nothing = event(4, "message.received", at: 9_880, [.refused(workflowID: "triage", folder: folder, reason: .disabled)])
        #expect(MessagesList.statusLine(unread: 0, last: MessagesList.lastConsequence([woke, nothing]), now: now)
                == "nothing woke 2 min ago")
        // No count and no message: no line.
        #expect(MessagesList.statusLine(unread: nil, last: nil, now: now) == nil)
        #expect(MessagesList.lastConsequence([event(5, "agent.started", at: 1)]) == nil)
        #expect(MessagesList.statusLine(unread: 3, last: nil, now: now) == "3 unread")
        // Each conversation once, across machines; a connector with no count adds nothing.
        let lists: [MessagesList.HostConversations] = [
            .init(host: Self.mac, name: "This Mac", conversations: [Self.item("slack", "C1", at: 1, unread: 2),
                                                                     Self.item("email", "t1", at: 2)]),
            .init(host: Self.box, name: "Box", conversations: [Self.item("slack", "C1", at: 1, unread: 2),
                                                               Self.item("slack", "C2", at: 3, unread: 5)]),
        ]
        #expect(MessagesList.unreadTotal(lists) == 7)
        #expect(MessagesList.unreadTotal([.init(host: Self.mac, name: "This Mac", conversations: [Self.item("email", "t", at: 1)])]) == nil)
    }
}
