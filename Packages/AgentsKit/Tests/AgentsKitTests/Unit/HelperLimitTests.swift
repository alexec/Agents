import Foundation
import Testing
@testable import AgentsKitCore

/// What counts against a project's two helper limits (028, #64).
@Suite("The limit on agents started by agents")
struct HelperLimitTests {
    private let project = URL(filePath: "/tmp/helper-limit-project")

    private func helper(_ state: AgentState, in folder: URL? = nil) -> Agent {
        var agent = Agent(runtimeID: "claude", cwd: folder ?? project)
        agent.state = state
        agent.startedByAgent = UUID()
        return agent
    }

    /// A helper working in a worktree still takes one of its project's places (030).
    @Test func aHelperInAWorktreeCountsInItsProject() {
        let root = project.appending(path: ".agents/worktrees/x")
        var inWorktree = helper(.running, in: root)
        inWorktree.worktree = AgentWorktree(name: "x", root: root, branch: "agents/x",
                                            project: project, base: "main", madeByApp: true)
        #expect(HelperLimit.placesInUse(in: project, agents: [inWorktree]) == 1)
        #expect(HelperLimit.placesInUse(in: root, agents: [inWorktree]) == 0)
    }

    @Test func theDefaultsAreThreeRunningAndFiveNotArchived() {
        let limits = HelperLimits().effective
        #expect(limits.running == 3)
        #expect(limits.notArchived == 5)
        #expect(HelperLimits().orNilIfDefault == nil)
    }

    // MARK: Running (#64)

    @Test func workingAndMidTurnHelpersAreRunning() {
        for state in [AgentState.starting, .running, .waitingOnUser] {
            #expect(HelperLimit.isRunning(helper(state)), "\(state)")
        }
    }

    @Test func finishedStoppedAndArchivedHelpersAreNotRunning() {
        for state in [AgentState.finished, .stopped, .archived] {
            #expect(!HelperLimit.isRunning(helper(state)), "\(state)")
        }
        #expect(HelperLimit.running(in: project, agents: [helper(.finished), helper(.stopped),
                                                          helper(.archived), helper(.running)]) == 1)
    }

    @Test func aParkedHelperIsNotRunningButOneParkingWhenItsTurnEndsIs() {
        var parked = helper(.finished)
        parked.parking = .parked(at: Date())
        #expect(!HelperLimit.isRunning(parked))
        var parking = helper(.running)
        parking.parking = .whenTurnEnds(since: Date())
        #expect(HelperLimit.isRunning(parking))
    }

    /// Blocked on agents or a time, or waiting on events or an allowance: the app
    /// carries it on by itself, so it holds a running place.
    @Test func aHelperTheAppWillResumeIsRunning() {
        var blocked = helper(.finished)
        blocked.report = WorkReport(outcome: .blocked, message: "Waiting on the build", at: Date(),
                                    block: Block(checkAgainAt: Date().addingTimeInterval(600)))
        #expect(HelperLimit.isRunning(blocked))

        var onEvents = helper(.finished)
        onEvents.eventWait = EventWait(patterns: [EventPattern("custom.ping")], from: 0, since: Date())
        #expect(HelperLimit.isRunning(onEvents))

        var onAllowance = helper(.stopped)
        onAllowance.endedReason = .allowanceSpent
        onAllowance.allowanceWait = AllowanceWait(resumeAt: Date().addingTimeInterval(600), entryID: nil,
                                                  runtimeID: "codex", text: "go", blocks: [], from: .person)
        #expect(HelperLimit.isRunning(onAllowance))

        let restarting = helper(.stopped)
        #expect(HelperLimit.isRunning(restarting, comingBack: [restarting.id]))
    }

    /// A block that named nothing waits for the person, not the app.
    @Test func aHelperOnlyThePersonCanCarryOnIsNotRunning() {
        var blocked = helper(.finished)
        blocked.report = WorkReport(outcome: .blocked, message: "Needs a key", at: Date(), block: Block())
        #expect(!HelperLimit.isRunning(blocked))
    }

    @Test func aStartUnderWayHoldsARunningPlace() {
        #expect(HelperLimit.running(in: project, agents: [helper(.running)], reserved: 2) == 3)
    }

    // MARK: The person's setting (#64)

    @Test func theSettingIsKeptWithinItsHardMaximums() {
        #expect(HelperLimits(running: 11).problem != nil)
        #expect(HelperLimits(running: 0).problem != nil)
        #expect(HelperLimits(notArchived: 21).problem != nil)
        #expect(HelperLimits(running: 10, notArchived: 20).problem == nil)
        #expect(HelperLimits(running: 6).problem
                == "Running helpers (6) cannot be more than helpers not yet archived (5).")
        // A hand-edited file is clamped, not obeyed.
        let edited = HelperLimits(running: 99, notArchived: 99).effective
        #expect(edited.running == HelperLimit.maximumRunning)
        #expect(edited.notArchived == HelperLimit.maximumNotArchived)
    }

    @Test func aProjectKeepsItsSettingAndOneWithoutReadsAsBefore() throws {
        let set = Project(folder: project, addedAt: Date(timeIntervalSince1970: 0),
                          helperLimits: HelperLimits(running: 2, notArchived: 8))
        let read = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(set))
        #expect(read.helperLimits == HelperLimits(running: 2, notArchived: 8))

        let old = #"{"folder":"file:///tmp/helper-limit-project","addedAt":0}"#
        let before = try JSONDecoder().decode(Project.self, from: Data(old.utf8))
        #expect(before.helperLimits == nil)
        #expect(before.unknownFields.isEmpty)
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
