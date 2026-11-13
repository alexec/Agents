import Foundation
import Testing
@testable import AgentsKitCore

/// What a window keeps of the event log: pages narrowed at the daemon, live events
/// taken only when they pass the same filter, and a way back to what it let go.
@MainActor
@Suite("The events a window keeps")
struct EventsPageModelTests {
    private let api = EventScope.folder(folder: URL(filePath: "/tmp/work/api"))
    private let web = EventScope.folder(folder: URL(filePath: "/tmp/work/web"))
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ position: EventPosition, _ name: String = "agent.finished",
                       _ scope: EventScope? = nil) -> Event {
        Event(EventDraft(name: name, at: t0.addingTimeInterval(TimeInterval(position)),
                         scope: scope ?? api, sentence: name, details: [:]),
              position: position)
    }

    private func page(_ events: [Event], hasMore: Bool = false) -> DaemonAPI.EventsPage {
        DaemonAPI.EventsPage(events: events, waiting: [], hasMore: hasMore)
    }

    /// Paging back stops at a bound (#3650), as live events are trimmed: the list says
    /// there is no more for it to take.
    @Test func pagingBackStopsAtItsBound() {
        let model = AgentsModel()
        let most = Int64(AgentsModel.eventsPagedMost)
        model.takeEvents(page((0..<1_000).map { event(most * 2 - $0) }, hasMore: true))
        var next = most * 2 - 1_000
        while model.moreEvents {
            model.takeEvents(page((0..<1_000).map { event(next - $0) }, hasMore: true), appending: true)
            next -= 1_000
        }
        #expect(model.recentEvents.count == AgentsModel.eventsPagedMost)
        #expect(model.recentEvents.first?.position == most * 2)
    }

    @Test func aFilterIsAskedOfTheDaemon() {
        let request = DaemonAPI.EventsListRequest(before: 9, EventFilter(scope: web, groups: [.mac, .agents]))
        #expect(request.before == 9)
        #expect(request.scope == web)
        #expect(request.groups == [.agents, .mac])
        #expect(DaemonAPI.EventsListRequest(EventFilter()).groups == nil)
    }

    @Test func aPageForAFilterSinceLeftIsDropped() {
        let model = AgentsModel()
        model.eventsFilter = EventFilter(scope: web)
        model.takeEvents(page([event(2), event(1)]), for: EventFilter())
        #expect(model.recentEvents.isEmpty)
        #expect(!model.eventsLoaded)
        model.takeEvents(page([event(3, "agent.finished", web)]), for: EventFilter(scope: web))
        #expect(model.recentEvents.map(\.position) == [3])
    }

    @Test func aLiveEventOutsideTheFilterIsNotTakenButStillCountsAsTheLast() {
        let model = AgentsModel()
        let filter = EventFilter(scope: web)
        model.eventsFilter = filter
        model.takeEvents(page([event(1, "agent.finished", web)]), for: filter)
        model.takeEvent(event(2))
        #expect(model.recentEvents.map(\.position) == [1])
        #expect(model.lastEventAt == event(2).latest)
        model.takeEvent(event(3, "agent.finished", web))
        #expect(model.recentEvents.map(\.position) == [3, 1])
    }

    @Test func trimmingTheOldestLeavesAWayBackToThem() {
        let model = AgentsModel()
        model.takeEvents(page((1...EventPosition(AgentsModel.eventsKept)).reversed().map { event($0) }))
        #expect(!model.moreEvents)
        model.takeEvent(event(EventPosition(AgentsModel.eventsKept) + 1))
        #expect(model.recentEvents.count == AgentsModel.eventsKept)
        #expect(model.moreEvents)
    }

    // MARK: The bus log (#4732)

    private func bus(_ n: Int, at seconds: TimeInterval, from machine: String = "linux-b",
                     type: String = "pr.merged", provider: String = "github") -> DaemonAPI.BusEvent {
        let subject = WireRef(provider: provider, type: "pr", topic: "alexec/agents", id: "\(n)")
        let time = ISO8601DateFormatter().string(from: t0.addingTimeInterval(seconds))
        return DaemonAPI.BusEvent(id: "\(subject)@\(type)", type: type, provider: provider, topic: "alexec/agents",
                                  subject: subject, time: time, producer: "agents:machine:#\(machine)")
    }

    /// The page shows this machine's events and the bus's that it does not have, by time;
    /// one that is on both is shown once, as this machine's.
    @Test func theBusLogsOtherEventsJoinTheList() {
        let model = AgentsModel()
        var mine = event(10, "pr.merged", .mac)
        mine.ref = bus(1, at: 10).id
        mine.provider = "github"
        mine.topic = "alexec/agents"
        model.takeEvents(DaemonAPI.EventsPage(events: [mine, event(5)], waiting: [], hasMore: false,
                                              producer: "agents:machine:#mac-mini"))
        model.takeBusLog(DaemonAPI.BusLogPage(events: [bus(2, at: 20), bus(1, at: 10, from: "mac-mini"), bus(3, at: 7)],
                                              next: "x", hasMore: true))
        let shown = model.shownEvents(EventFilter())
        #expect(shown.events.map(\.position) == [-1, 10, -3, 5])
        #expect(shown.events.first?.sentence == "pr.merged on github:pr:alexec/agents#2")
        #expect(shown.events.first?.producerMachine == "linux-b")
        #expect(model.eventsProducer == "agents:machine:#mac-mini")
        #expect(model.moreEventsAnywhere)
        // A folder's page has none of another machine's.
        #expect(model.shownEvents(EventFilter(scope: api)).events.map(\.position) == [5])
        // Paging back goes on below the positions it gave.
        model.takeBusLog(DaemonAPI.BusLogPage(events: [bus(4, at: 1)], hasMore: false), appending: true)
        #expect(model.busEvents.map(\.position) == [-1, -2, -3, -4])
        #expect(!model.moreEventsAnywhere)
    }

    /// The Events page's "Last update" line (#5146) is the time of the newest page's read: a
    /// page from further back leaves it, and a new list clears it.
    @Test func theBusLogKeepsWhenItsNewestPageWasRead() {
        let model = AgentsModel()
        #expect(model.busReadAt == nil)
        let before = Date()
        model.takeBusLog(DaemonAPI.BusLogPage(events: [bus(1, at: 10)], next: "x", hasMore: true))
        let read = model.busReadAt
        #expect(read.map { $0 >= before } == true)
        model.takeBusLog(DaemonAPI.BusLogPage(events: [bus(2, at: 1)], hasMore: false), appending: true)
        #expect(model.busReadAt == read)
        model.clearEvents()
        #expect(model.busReadAt == nil)
    }

    @Test func theEnvelopesFieldsNarrowTheList() {
        let model = AgentsModel()
        model.takeBusLog(DaemonAPI.BusLogPage(events: [bus(1, at: 3), bus(2, at: 2, type: "issue.created", provider: "jira")],
                                              hasMore: false))
        let jira = EventFilter(provider: "jira")
        model.eventsFilter = jira
        model.takeBusLog(DaemonAPI.BusLogPage(events: [bus(2, at: 2, type: "issue.created", provider: "jira")], hasMore: false),
                         for: jira)
        #expect(model.shownEvents(jira).events.map(\.type) == ["issue.created"])
        #expect(model.shownEvents(EventFilter(type: "pr.merged")).events.isEmpty)
        #expect(EventFilter(provider: "jira", type: "issue.*", topic: "abc").busLogQuery(before: "n", limit: 5)
            == DaemonAPI.BusLogQuery(before: "n", limit: 5, provider: "jira", type: "issue.*", topic: "abc"))
        // An event from before the envelope matches by its name.
        #expect(EventFilter(type: "agent.finished").matches(event(1)))
        #expect(!EventFilter(provider: "github").matches(event(1)))
    }
}
