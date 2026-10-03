import Foundation
import Testing
@testable import AgentsKitCore

/// What the Mac window's busiest views cost per redraw over a large model: 2,000 agents
/// held and 1,000 events (#135, #136, #137). Timings, so they say nothing on their own
/// and run only when asked: `AGENTS_BENCH=1 swift test --filter RedrawCostBenchmarks`.
/// Each prints the median of six runs.
@MainActor
@Suite("Redraw cost over a large model",
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_BENCH"] == "1", "set AGENTS_BENCH=1 to time"))
struct RedrawCostBenchmarks {
    static let folders = (0..<10).map { URL(filePath: "/Users/bench/src/project\($0)") }
    static let key = ProjectKey(host: .mac, folder: folders[0])

    /// 2,000 agents: the selected project has 1,000 archived, 5 working and 45 finished;
    /// the other 950 are spread over nine more projects.
    static func agents() -> [Agent] {
        let now = Date()
        var agents: [Agent] = []
        for index in 0..<2_000 {
            let folder: URL
            let state: AgentState
            switch index {
            case 0..<1_000: (folder, state) = (folders[0], .archived)
            case 1_000..<1_005: (folder, state) = (folders[0], .running)
            case 1_005..<1_050: (folder, state) = (folders[0], .finished)
            default: (folder, state) = (folders[1 + index % 9], index.isMultiple(of: 3) ? .archived : .finished)
            }
            agents.append(Agent(runtimeID: "claude", cwd: folder, title: "agent \(index)", state: state,
                                lastActivityAt: now.addingTimeInterval(-Double(index))))
        }
        return agents
    }

    static func median(_ runs: Int = 6, _ body: () -> Void) -> Duration {
        var times: [Duration] = []
        for _ in 0..<runs {
            let started = ContinuousClock.now
            body()
            times.append(ContinuousClock.now - started)
        }
        return times.sorted()[runs / 2]
    }

    /// The calls the Sessions column's `body` made before #135: each live group's
    /// list, `hasLive`, the archived fold, `liveCount`, and `hasAny` over every group.
    static func sessionsColumnCalls(_ model: AgentsModel) -> Int {
        var seen = 0
        for group in AgentGroup.live { seen += model.agents(in: key, group: group).count }
        for group in AgentGroup.live { seen += model.agents(in: key, group: group).isEmpty ? 0 : 1 }
        seen += model.agents(in: key, group: .archived).count
        for group in AgentGroup.live { seen += model.agents(in: key, group: group).count }
        for group in AgentGroup.allCases { seen += model.agents(in: key, group: group).isEmpty ? 0 : 1 }
        return seen
    }

    @Test func sessionsColumnRedraw() {
        let model = AgentsModel()
        model.replaceAgents(Self.agents())
        _ = Self.sessionsColumnCalls(model)
        let redraw = Self.median { for _ in 0..<10 { _ = Self.sessionsColumnCalls(model) } }
        // One agent's update, then the column drawn again: what each `agent/changed` costs.
        var working = model.agents.first { $0.state == .running }!
        let change = Self.median {
            for _ in 0..<10 {
                working.lastActivityAt = Date()
                model.upsert(working)
                _ = Self.sessionsColumnCalls(model)
            }
        }
        print("BENCH #135 sessions column, 2000 agents: redraw \(redraw / 10), change+redraw \(change / 10)")
    }

    @Test func takeListedFiveHundredIntoTwoThousand() {
        let all = Self.agents()
        let held = Array(all.prefix(2_000))
        // 250 already held and 250 new: what an archived list or a workflow's runs bring.
        let listed = Array(held.suffix(250)) + Self.agents().prefix(250)
        var model = AgentsModel()
        let took = Self.median {
            model = AgentsModel()
            model.replaceAgents(held)
            model.takeListed(listed)
        }
        let setUp = Self.median {
            model = AgentsModel()
            model.replaceAgents(held)
        }
        #expect(model.agents.count == 2_000)
        print("BENCH #136 takeListed 500 into 2000: \(took - setUp) (set-up \(setUp) taken off)")
    }

    static func events() -> [Event] {
        let start = Date().addingTimeInterval(-14 * 86_400)
        return (1...1_000).reversed().map { position in
            let folder = folders[position % 3]
            return Event(EventDraft(name: "agent.finished", at: start.addingTimeInterval(Double(position) * 1_200),
                                    scope: .project(folder: Project.standardize(folder)),
                                    sentence: "finished", details: [:]),
                         position: EventPosition(position))
        }
    }

    /// What `EventsView.body` did before #137: the filter for `isEmpty`, again for the
    /// days, each event's day worked out, and again for the unseen count.
    static func eventsViewBeforeCalls(_ model: AgentsModel, _ filter: EventFilter) -> Int {
        let calendar = Calendar.current
        let events = { model.recentEvents.filter(filter.matches) }
        var seen = events().isEmpty ? 0 : 1
        var days: [(day: Date, events: [Event])] = []
        for event in events() {
            let day = calendar.startOfDay(for: event.at)
            if days.last?.day == day { days[days.count - 1].events.append(event) } else { days.append((day, [event])) }
        }
        seen += days.count
        seen += events().filter { $0.position > 500 }.count
        return seen
    }

    @Test func eventsRedraw() {
        let model = AgentsModel()
        model.takeEvents(DaemonAPI.EventsPage(events: Self.events(), waiting: [], hasMore: false))
        let filter = EventFilter(scope: .project(folder: Project.standardize(Self.folders[0])))
        let before = Self.median { for _ in 0..<10 { _ = Self.eventsViewBeforeCalls(model, filter) } }
        print("BENCH #137 events view (old body pattern), 1000 events: redraw \(before / 10)")
    }
}
