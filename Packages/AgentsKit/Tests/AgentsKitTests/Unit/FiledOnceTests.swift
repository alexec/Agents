import Foundation
import Testing
@testable import AgentsKitCore

/// What the window derives once per change rather than once per redraw (#135, #136,
/// #137) answers what the passes it replaced answered, change after change.
@MainActor
@Suite("Derived once per change")
struct FiledOnceTests {
    private let api = URL(filePath: "/tmp/work/api")
    private let web = URL(filePath: "/tmp/work/web")
    private let devbox = HostID(rawValue: "devbox01")
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func agent(_ folder: URL, _ state: AgentState, at offset: Double, host: HostID = .mac) -> Agent {
        var agent = Agent(runtimeID: "claude", cwd: folder, title: "t", state: state,
                          lastActivityAt: t0.addingTimeInterval(offset))
        agent.host = host
        return agent
    }

    /// `agents(in:group:)` as it was: a pass over everything held.
    private func scanned(_ model: AgentsModel, _ folder: URL, _ group: AgentGroup, host: HostID? = nil) -> [UUID] {
        let wanted = Project.standardize(folder)
        let found = model.agents.filter {
            $0.projectFolder == wanted && model.group(of: $0) == group && (host == nil || $0.host == host)
        }
        guard group == .parked else { return found.map(\.id) }
        return found.sorted { ($0.parking?.parkedAt ?? .distantPast) > ($1.parking?.parkedAt ?? .distantPast) }.map(\.id)
    }

    private func expectAgreement(_ model: AgentsModel, _ note: Comment) {
        for folder in [api, web] {
            for group in AgentGroup.allCases {
                #expect(model.agents(in: folder, group: group).map(\.id) == scanned(model, folder, group), note)
                for host in [HostID.mac, devbox] {
                    #expect(model.agents(in: ProjectKey(host: host, folder: folder), group: group).map(\.id)
                            == scanned(model, folder, group, host: host), note)
                }
            }
            let key = ProjectKey(host: .mac, folder: folder)
            let held = model.agents.filter { $0.projectFolder == Project.standardize(folder) }
            let mine = held.filter { $0.host == .mac }
            #expect(model.unreadCount(in: folder) == held.count(where: \.showsUnread), note)
            #expect(model.unreadCount(in: key) == mine.count(where: \.showsUnread), note)
            #expect(model.attentionCount(in: folder) == held.count(where: model.wantsALook), note)
            #expect(model.attentionCount(in: key) == mine.count(where: model.wantsALook), note)
            var counts: [AgentGroup: Int] = [:]
            for one in mine { counts[model.group(of: one), default: 0] += 1 }
            #expect(model.counts(in: key) == counts, note)
        }
    }

    @Test func theBucketsAgreeWithAScanAfterEveryChange() throws {
        let model = AgentsModel()
        var agents: [Agent] = []
        for (index, state) in AgentState.allCases.enumerated() {
            agents.append(agent(api, state, at: Double(index)))
            agents.append(agent(web, state, at: Double(index) + 0.5))
            agents.append(agent(api, state, at: Double(index) + 0.25, host: devbox))
        }
        var older = agent(api, .finished, at: 20); older.parking = .parked(at: t0)
        var newer = agent(api, .finished, at: 10); newer.parking = .parked(at: t0.addingTimeInterval(60))
        var unread = agent(api, .finished, at: 30); unread.isUnread = true
        model.replaceAgents(agents + [older, newer, unread])
        expectAgreement(model, "listed")
        #expect(model.agents(in: api, group: .parked).map(\.id) == [newer.id, older.id], "most recently parked first")

        var moved = agents[1]
        moved.state = .running
        moved.lastActivityAt = t0.addingTimeInterval(100)
        model.upsert(moved)
        expectAgreement(model, "an agent changed")
        #expect(model.agent(moved.id)?.state == .running, "the index has the new copy")

        model.apply(DaemonAPI.Notification.agentShowFile,
                    try JSONValue.encoding(DaemonAPI.ShowFileNotification(agentID: moved.id,
                                                                          file: ShownFile(path: "/tmp/work/web/a"))))
        expectAgreement(model, "a file to show")
        #expect(model.agents(in: web, group: .needsAttention).contains { $0.id == moved.id })
        _ = model.takeFileToShow(for: moved.id)
        expectAgreement(model, "the file seen")

        model.apply(DaemonAPI.Notification.agentRemoved,
                    try JSONValue.encoding(DaemonAPI.AgentRemovedNotification(agentID: unread.id)))
        expectAgreement(model, "an agent removed")
        #expect(model.agent(unread.id) == nil)
    }

    @Test func takingAListMergesKeepsListsAndSortsOnce() {
        let model = AgentsModel()
        var held = agent(api, .finished, at: 0)
        held.availableCommands = [SlashCommand(name: "review", description: "")]
        let other = agent(api, .finished, at: 5)
        model.replaceAgents([held, other])

        var lean = held
        lean.availableCommands = []
        lean.lastActivityAt = t0.addingTimeInterval(10)
        let fresh = agent(web, .archived, at: 2)
        model.takeListed([lean, fresh])

        #expect(model.agents.map(\.id) == [held.id, other.id, fresh.id], "newest first")
        #expect(model.agent(held.id)?.availableCommands.map(\.name) == ["review"], "a lean one keeps its lists")
        #expect(model.agent(held.id)?.lastActivityAt == lean.lastActivityAt)
        model.takeListed([])
        #expect(model.agents.count == 3)
    }

    private func event(_ position: EventPosition, _ folder: URL, at offset: Double) -> Event {
        Event(EventDraft(name: "agent.finished", at: t0.addingTimeInterval(offset),
                         scope: .project(folder: folder), sentence: "finished", details: [:]),
              position: position)
    }

    @Test func shownEventsFollowTheEventsAndTheFilter() {
        let model = AgentsModel()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day: Double = 86_400
        model.takeEvents(DaemonAPI.EventsPage(events: [event(4, api, at: day + 60), event(3, web, at: day),
                                                       event(2, api, at: 60), event(1, api, at: 0)],
                                              waiting: [], hasMore: false))
        let all = model.shownEvents(EventFilter(), calendar: calendar)
        #expect(all.events.map(\.position) == [4, 3, 2, 1])
        #expect(all.days.map { $0.events.map(\.position) } == [[4, 3], [2, 1]])

        let onlyAPI = EventFilter(scope: .project(folder: api))
        #expect(model.shownEvents(onlyAPI, calendar: calendar).days.map { $0.events.map(\.position) } == [[4], [2, 1]])

        model.takeEvent(event(5, api, at: day + 120))
        #expect(model.shownEvents(onlyAPI, calendar: calendar).events.map(\.position) == [5, 4, 2, 1],
                "a new event is shown, not the copy worked out before it")
        #expect(model.shownEvents(EventFilter(), calendar: calendar).events.count == 5)
    }
}
