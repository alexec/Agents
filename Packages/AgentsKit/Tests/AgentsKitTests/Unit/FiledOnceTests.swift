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
}
