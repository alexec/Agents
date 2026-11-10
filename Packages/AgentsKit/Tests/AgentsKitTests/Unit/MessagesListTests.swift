import Foundation
import Testing
@testable import AgentsKitCore

/// The Messages page's list (#4344): the machines' conversations in one list, and its types on the wire.
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
                                                      lastActivity: "2026-11-10T08:00:00Z", link: "https://x.slack.com/archives/C1"))],
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
    }
}
