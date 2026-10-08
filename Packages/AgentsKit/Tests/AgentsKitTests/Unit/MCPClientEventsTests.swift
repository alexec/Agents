import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The daemon's client speaking the events draft's poll mode (#383,
/// contracts/mcp-events-client.md) to a stand-in.
@Suite("MCP client events")
struct MCPClientEventsTests {
    private func client(_ stand: EventsServerStandIn,
                        notified: (@Sendable (String) -> Void)? = nil) -> MCPClient {
        MCPClient(server: MCPServer(name: stand.name, transport: .http(url: stand.url, headers: [:])),
                  cwd: URL(fileURLWithPath: NSTemporaryDirectory()), timeout: .seconds(5), log: { _ in },
                  http: stand.send, offering: MCPEventsWire.protocolVersions, onNotification: notified)
    }

    @Test func anEventConnectionOffersTheNewerVersionAndReadsTheCapability() async throws {
        let stand = EventsServerStandIn()
        let client = client(stand)
        let info = try await client.connect()
        #expect(info.protocolVersion == "2026-07-28")
        #expect(await client.eventsCapability == EventsCapability(listChanged: true))
    }

    @Test func aServerWithoutEventsHasNoCapability() async throws {
        let stand = EventsServerStandIn()
        stand.offerNoEvents()
        let client = client(stand)
        try await client.connect()
        #expect(await client.eventsCapability == nil)
    }

    @Test func itListsTheEvents() async throws {
        let stand = EventsServerStandIn(events: [EventsServerStandIn.checksFailed, EventsServerStandIn.prMerged])
        let client = client(stand)
        try await client.connect()
        let events = try await client.listEvents()
        #expect(events.map(\.name) == ["checks.failed", "pr.merged"])
        #expect(events[0].offersPoll)
        #expect(events[0].inputSchema?["required"] == ["repo"])
    }

    @Test func aNullCursorStartsFromNowAndTheCursorFollows() async throws {
        let stand = EventsServerStandIn()
        stand.raise("before")
        let client = client(stand)
        try await client.connect()
        let first = try await client.pollEvents(EventsPollRequest(name: "checks.failed", arguments: ["repo": "x"], cursor: nil))
        #expect(first.events.isEmpty)
        #expect(first.cursor == "1")
        stand.raise("after", data: ["pr": 2])
        stand.hint(nextPollMs: 12_000)
        let second = try await client.pollEvents(EventsPollRequest(name: "checks.failed", arguments: ["repo": "x"],
                                                                   cursor: first.cursor))
        #expect(second.events == [PolledEvent(eventId: "after", name: "checks.failed",
                                              timestamp: "2026-10-06T12:05:00Z", data: ["pr": 2])])
        #expect(second.nextPollMs == 12_000)
        #expect(stand.polls.map(\.cursor) == [nil, "1"])
        #expect(stand.polls.first?.arguments == ["repo": "x"])
    }

    @Test func theDraftsErrorsAreTold() async throws {
        let stand = EventsServerStandIn()
        let client = client(stand)
        try await client.connect()
        let request = EventsPollRequest(name: "checks.failed", arguments: [:], cursor: nil)
        func error() async -> MCPEventsError? {
            do { _ = try await client.pollEvents(request); return nil } catch let failure as MCPClient.Failure {
                return MCPEventsError(failure)
            } catch { return nil }
        }
        stand.fail(code: -32011, message: "gone")
        #expect(await error() == .notFound("gone"))
        stand.fail(code: -32012, message: "no")
        #expect(await error() == .forbidden("no"))
        stand.fail(code: -32013, data: ["retryAfterMs": 60_000])
        #expect(await error() == .resourceExhausted(retryAfterMs: 60_000))
        stand.fail(code: -32014, message: "changed", data: ["reason": "schema_changed"])
        #expect(await error() == .unsupported(reason: "schema_changed", message: "changed"))
        stand.fail(code: -32602, message: "repo is required")
        #expect(await error() == .invalidParams("repo is required"))
        stand.recover()
        stand.goDown()
        guard case .transport? = await error() else { Issue.record("not a transport error"); return }
    }

    @Test func aListChangedNotificationInAStreamIsHeard() {
        let stream = Data("""
            event: message
            data: {"jsonrpc":"2.0","method":"notifications/events/list_changed"}

            event: message
            data: {"jsonrpc":"2.0","id":3,"result":{}}

            """.utf8)
        #expect(MCPClient.notifications(inEvents: stream) == ["notifications/events/list_changed"])
    }
}
