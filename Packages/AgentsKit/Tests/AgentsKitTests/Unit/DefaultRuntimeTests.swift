import Foundation
import Testing
@testable import AgentsKitCore

/// Which runtime a new agent is offered when nobody has said, the one rule the Mac and a
/// phone both read (029).
@Suite("The runtime a new agent is offered first")
@MainActor
struct DefaultRuntimeTests {
    private func agent(_ runtimeID: String, minutesAgo: Double) -> Agent {
        var agent = Agent(runtimeID: runtimeID, cwd: URL(filePath: "/tmp"))
        agent.lastActivityAt = Date(timeIntervalSinceNow: -minutesAgo * 60)
        return agent
    }

    @Test func withNoAgentsItIsTheFirstAvailableInOrder() {
        let model = AgentsModel()
        #expect(model.defaultRuntimeID(available: ["codex", "claude"]) == "codex")
        #expect(model.defaultRuntimeID(available: []) == nil)
    }

    @Test func theMostRecentAgentsRuntimeWinsWhenItIsAvailable() {
        let model = AgentsModel()
        model.replaceAgents([agent("codex", minutesAgo: 30), agent("claude", minutesAgo: 1)])
        #expect(model.defaultRuntimeID(available: ["codex", "claude"]) == "claude")
    }

    @Test func aRecentRuntimeThatCannotStartIsPassedOver() {
        let model = AgentsModel()
        model.replaceAgents([agent("gemini", minutesAgo: 1), agent("codex", minutesAgo: 30)])
        #expect(model.defaultRuntimeID(available: ["claude", "codex"]) == "codex")
        model.replaceAgents([agent("gemini", minutesAgo: 1)])
        #expect(model.defaultRuntimeID(available: ["claude", "codex"]) == "claude")
    }
}
