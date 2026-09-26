import Foundation
import Testing
@testable import AgentsKitCore

/// What a window keeps of the event log: pages narrowed at the daemon, live events
/// taken only when they pass the same filter, and a way back to what it let go.
@MainActor
@Suite("The events a window keeps")
struct EventsPageModelTests {
    private let api = EventScope.project(folder: URL(filePath: "/tmp/work/api"))
    private let web = EventScope.project(folder: URL(filePath: "/tmp/work/web"))
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
}
