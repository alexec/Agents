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

    @Test func withNothingUsedItUsesTheFirstAvailableInOrder() {
        let model = AgentsModel()
        #expect(model.defaultRuntimeID(available: ["antigravity", "claude"], kept: nil) == "antigravity")
        #expect(model.defaultRuntimeID(available: ["gemini", "codex"], kept: nil) == "gemini")
        #expect(model.defaultRuntimeID(available: [], kept: nil) == nil)
    }

    /// The most recently active agent reflects the runtime the person last used.
    @Test func theLastUsedRuntimeWinsOverTheKeptChoiceWhenItCanStart() {
        let model = AgentsModel()
        model.replaceAgents([agent("claude", minutesAgo: 20), agent("codex", minutesAgo: 1)])
        #expect(model.defaultRuntimeID(available: ["claude", "codex", "grok"], kept: "grok") == "codex")
        #expect(model.defaultRuntimeID(available: ["claude", "codex"], kept: nil) == "codex")
    }

    /// Each machine's last runtime follows its newest agent, as one changes, comes or goes,
    /// so a page reads it rather than every agent (#2732).
    @Test func eachMachineKeepsItsLastRuntime() {
        let model = AgentsModel()
        let box = MachineRef(rawValue: "box")
        var far = agent("grok", minutesAgo: 5)
        far.host = box
        let older = agent("claude", minutesAgo: 20)
        var newer = agent("codex", minutesAgo: 1)
        model.replaceAgents([older, newer, far])
        #expect(model.lastRuntimes == [.mac: "codex", box: "grok"])

        model.forget([newer.id])
        #expect(model.lastRuntimes == [.mac: "claude", box: "grok"])

        newer.lastActivityAt = Date()
        model.upsert(newer)
        #expect(model.lastRuntimes[.mac] == "codex")

        model.forget([far.id])
        #expect(model.lastRuntimes == [.mac: "codex"])
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

    @Test func lastUsedThenKeptRuntimeThatCannotStartArePassedOver() {
        let model = AgentsModel()
        model.replaceAgents([agent("gemini", minutesAgo: 1)])
        #expect(model.defaultRuntimeID(available: ["claude", "codex"], kept: "claude") == "claude")
        #expect(model.defaultRuntimeID(available: ["codex"], kept: "gemini") == "codex")
    }

    /// A start form opened before its host listed any runtime gets one when they come
    /// (#977), and one already on a runtime that can start stays there.
    @Test func runtimesThatArriveAfterTheFormOpenedGiveItARuntime() {
        #expect(RuntimeCatalog.startFormRuntime(current: nil, lastUsed: nil, kept: "codex", available: []) == nil)
        #expect(RuntimeCatalog.startFormRuntime(current: nil, lastUsed: nil, kept: "codex", available: ["claude", "codex"]) == "codex")
        #expect(RuntimeCatalog.startFormRuntime(current: nil, lastUsed: "codex", kept: nil, available: ["claude", "codex"]) == "codex")
        #expect(RuntimeCatalog.startFormRuntime(current: "codex", lastUsed: "claude", kept: "grok", available: ["claude", "codex", "grok"]) == "codex")
        #expect(RuntimeCatalog.startFormRuntime(current: "codex", lastUsed: nil, kept: nil, available: ["claude"]) == "claude")
    }
}
