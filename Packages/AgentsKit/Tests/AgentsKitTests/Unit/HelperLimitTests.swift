import Foundation
import Testing
@testable import AgentsKitCore

/// What counts against a project's three (028).
@Suite("The limit on agents started by agents")
struct HelperLimitTests {
    private let project = URL(filePath: "/tmp/helper-limit-project")

    private func helper(_ state: AgentState, in folder: URL? = nil) -> Agent {
        var agent = Agent(runtimeID: "claude", cwd: folder ?? project)
        agent.state = state
        agent.startedByAgent = UUID()
        return agent
    }

    @Test func threeIsTheLimit() {
        #expect(HelperLimit.perProject == 3)
    }

    @Test func stoppedAndFinishedHelpersStillHoldTheirPlace() {
        let agents = [helper(.running), helper(.stopped), helper(.finished)]
        #expect(HelperLimit.placesInUse(in: project, agents: agents) == 3)
    }

    @Test func onlyArchivingGivesAPlaceBack() {
        let agents = [helper(.running), helper(.archived)]
        #expect(HelperLimit.placesInUse(in: project, agents: agents) == 1)
    }

    @Test func thePersonsOwnAgentsNeverCount() {
        let persons = Agent(runtimeID: "claude", cwd: project)
        var workflows = Agent(runtimeID: "claude", cwd: project)
        workflows.startedByWorkflow = "nightly"
        #expect(HelperLimit.placesInUse(in: project, agents: [persons, workflows]) == 0)
    }

    @Test func anotherProjectsHelpersDoNotCount() {
        let elsewhere = helper(.running, in: URL(filePath: "/tmp/somewhere-else"))
        #expect(HelperLimit.placesInUse(in: project, agents: [elsewhere]) == 0)
    }

    @Test func theSameFolderSpelledDifferentlyIsTheSameProject() {
        let spelled = helper(.running, in: URL(filePath: "/tmp/helper-limit-project/"))
        #expect(HelperLimit.placesInUse(in: project, agents: [spelled]) == 1)
    }

    @Test func aStartUnderWayHoldsItsPlace() {
        #expect(HelperLimit.placesInUse(in: project, agents: [helper(.running)], reserved: 2) == 3)
    }
}
