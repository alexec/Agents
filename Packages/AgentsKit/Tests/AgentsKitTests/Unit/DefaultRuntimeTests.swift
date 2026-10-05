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

    @Test func withNothingKeptItIsTheCatalogDefaultThenTheFirstAvailableInOrder() {
        let model = AgentsModel()
        #expect(model.defaultRuntimeID(available: ["antigravity", "claude"], kept: nil) == "claude")
        #expect(model.defaultRuntimeID(available: ["gemini", "codex"], kept: nil) == "gemini")
        #expect(model.defaultRuntimeID(available: [], kept: nil) == nil)
    }

    /// The start form's runtime, not the last agent's (#264): a helper an agent started on
    /// another runtime is not the person choosing it.
    @Test func theKeptRuntimeWinsAndTheLastAgentDoesNot() {
        let model = AgentsModel()
        model.replaceAgents([agent("codex", minutesAgo: 1)])
        #expect(model.defaultRuntimeID(available: ["claude", "codex", "grok"], kept: "grok") == "grok")
        #expect(model.defaultRuntimeID(available: ["claude", "codex"], kept: nil) == "claude")
    }

    /// The mode is the daemon's memory, kept current by `modes/changed` (029).
    @Test func theRememberedModeFollowsTheMac() throws {
        let model = AgentsModel()
        model.replaceRememberedModes(["claude": "default"])
        #expect(model.rememberedMode(for: "claude") == "default")
        #expect(model.apply(DaemonAPI.Notification.modesChanged,
                            try JSONValue.encoding(["claude": "plan"] as DaemonAPI.RememberedModes)))
        #expect(model.rememberedMode(for: "claude") == "plan")
        #expect(model.rememberedMode(for: "codex") == nil)
    }

    @Test func aKeptRuntimeThatCannotStartIsPassedOver() {
        let model = AgentsModel()
        #expect(model.defaultRuntimeID(available: ["claude", "codex"], kept: "gemini") == "claude")
        #expect(model.defaultRuntimeID(available: ["codex"], kept: "gemini") == "codex")
    }
}
