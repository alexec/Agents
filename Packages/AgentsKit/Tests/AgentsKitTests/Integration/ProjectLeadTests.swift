import Foundation
import Testing
@testable import AgentsKit

/// A lead exists from the moment a project does, costs nothing until it is spoken to,
/// and goes away with its project rather than on its own.
@Suite("The project lead", .timeLimit(.minutes(1)))
struct ProjectLeadTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsLeadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(root))
    }

    private func folder(_ root: URL, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Project.standardize(url)
    }

    private func core(_ locations: StoreLocations, seeded: [Agent] = []) async throws -> DaemonCore {
        let store = try AgentStore(locations: locations)
        for agent in seeded { try await store.save(agent) }
        let core = DaemonCore(store: store,
                              locations: locations,
                              discovery: .findsEverything,
                              launcher: FakeLauncher(script: FakeACPAgent.Script()))
        await core.loadFromDisk()
        return core
    }

    private func worker(in folder: URL, title: String, state: AgentState = .finished) -> Agent {
        Agent(runtimeID: "claude", cwd: folder, title: title, state: state,
              endedReason: .endTurn, role: .worker)
    }

    @Test func addingAProjectGivesItALeadThatIsNotRunning() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations)

        let summary = try await core.addProject(work)
        #expect(summary.leadID != nil, "every project has one")

        let lead = await core.lead(in: work)
        #expect(lead?.role == .lead)
        #expect(lead?.runtimeSessionID == nil, "nothing was started")
        #expect(lead?.state == .stopped, "and nothing is running")
    }

    @Test func aLeadIsMadeOnceAndNotAgain() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations)

        _ = try await core.addProject(work)
        let first = await core.lead(in: work)?.id
        _ = try await core.addProject(work)
        #expect(await core.lead(in: work)?.id == first)
    }

    @Test func theLeadIsNotCountedInTheGroups() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations, seeded: [worker(in: work, title: "Real work")])

        _ = try await core.addProject(work)
        let summary = try #require(await core.projectSummary(for: work))
        #expect(summary.counts.values.reduce(0, +) == 1, "the lead is in none of them")
        #expect(summary.leadID != nil)
    }

    @Test func aLeadCannotBeArchivedOnItsOwn() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations)
        _ = try await core.addProject(work)
        let lead = try #require(await core.lead(in: work))

        await #expect(throws: JSONRPCError.self) {
            try await core.archive(lead.id)
        }
    }

    @Test func archivingAProjectTakesItsLeadAndBringsItBack() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations)
        _ = try await core.addProject(work)

        _ = try await core.archiveProject(work)
        #expect(await core.lead(in: work)?.state == .archived)

        _ = try await core.unarchiveProject(work)
        let back = await core.lead(in: work)
        #expect(back?.state != .archived, "it comes back with its project")
        #expect(back?.role == .lead)
    }

    @Test func aWorkingAgentBlocksArchivingAndIsNamed() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations,
                                  seeded: [worker(in: work, title: "Fix the parser", state: .running)])
        _ = try await core.addProject(work)

        do {
            _ = try await core.archiveProject(work)
            Issue.record("archiving should have been refused")
        } catch let error as JSONRPCError {
            #expect(error.code == DaemonAPI.Failure.projectHasLiveAgents)
            #expect(error.message.contains("Fix the parser"), "the refusal says what to stop")
        }
    }

    @Test func aWorkingLeadBlocksArchivingAndIsNamedAsTheLead() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations)
        _ = try await core.addProject(work)
        let lead = try #require(await core.lead(in: work))
        await core.setStateForTesting(lead.id, .running)

        do {
            _ = try await core.archiveProject(work)
            Issue.record("archiving should have been refused")
        } catch let error as JSONRPCError {
            #expect(error.message.contains("the project lead"))
        }
    }

    @Test func archivingAProjectLeavesItsWorkersAlone() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations, seeded: [
            worker(in: work, title: "Done"),
            worker(in: work, title: "Stopped", state: .stopped),
        ])
        _ = try await core.addProject(work)

        _ = try await core.archiveProject(work)
        let states = await core.allAgents()
            .filter { $0.role == .worker }
            .map(\.state)
        #expect(Set(states) == [.finished, .stopped],
                "their own states are what unarchiving restores")
    }

    @Test func onlyALeadIsToldItMayUseTheTools() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations, seeded: [worker(in: work, title: "A worker")])
        _ = try await core.addProject(work)

        let lead = try #require(await core.lead(in: work))
        let worker = try #require(await core.allAgents().first { $0.role == .worker })

        let leadToken = await core.bindTokenForTesting(to: lead.id)
        let workerToken = await core.bindTokenForTesting(to: worker.id)
        #expect(await core.isLead(token: leadToken))
        #expect(await core.isLead(token: workerToken) == false)
        #expect(await core.isLead(token: "not a token") == false)
    }

    @Test func aWorkerCallingATooIsRefusedWhateverTheToken() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations, seeded: [worker(in: work, title: "A worker")])
        _ = try await core.addProject(work)
        let worker = try #require(await core.allAgents().first { $0.role == .worker })
        let token = await core.bindTokenForTesting(to: worker.id)

        let answer = try await core.callLeadTool(
            DaemonAPI.LeadToolRequest(token: token, tool: "list_agents"))
        #expect(answer == "Only a project lead can do that.")
    }

    @Test func readsAreServedWithoutAskingAnybody() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations, seeded: [worker(in: work, title: "Fix the parser")])
        _ = try await core.addProject(work)
        let lead = try #require(await core.lead(in: work))
        let token = await core.bindTokenForTesting(to: lead.id)

        // No permission is pending afterwards: a read is recorded, not asked about.
        let answer = try await core.callLeadTool(
            DaemonAPI.LeadToolRequest(token: token, tool: "list_agents"))
        #expect(answer.contains("Fix the parser"))
        #expect(await core.pendingPermissionRequests().isEmpty)
    }

    @Test func aLeadCannotReachAnotherProjectsAgent() async throws {
        let (locations, root) = try temporary()
        let mine = try folder(root, "api")
        let theirs = try folder(root, "web")
        let core = try await core(locations, seeded: [worker(in: theirs, title: "Not yours")])
        _ = try await core.addProject(mine)
        _ = try await core.addProject(theirs)

        let lead = try #require(await core.lead(in: mine))
        let token = await core.bindTokenForTesting(to: lead.id)
        let elsewhere = try #require(await core.allAgents().first { $0.title == "Not yours" })

        let answer = try await core.callLeadTool(
            DaemonAPI.LeadToolRequest(token: token, tool: "read_transcript", agentID: elsewhere.id))
        #expect(answer.contains("another project"))
    }

    @Test func aLeadCannotStopItself() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations)
        _ = try await core.addProject(work)
        let lead = try #require(await core.lead(in: work))
        let token = await core.bindTokenForTesting(to: lead.id)

        let answer = try await core.callLeadTool(
            DaemonAPI.LeadToolRequest(token: token, tool: "stop_agent", agentID: lead.id))
        #expect(answer == "You cannot stop yourself. Ask the user to stop you.")
        #expect(await core.pendingPermissionRequests().isEmpty,
                "refused before anybody was asked anything")
    }

    @Test func changingSomethingRaisesTheOrdinaryPermissionQuestion() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations, seeded: [worker(in: work, title: "Working",
                                                             state: .running)])
        _ = try await core.addProject(work)
        let lead = try #require(await core.lead(in: work))
        let token = await core.bindTokenForTesting(to: lead.id)
        let target = try #require(await core.allAgents().first { $0.title == "Working" })

        let call = Task {
            try await core.callLeadTool(
                DaemonAPI.LeadToolRequest(token: token, tool: "stop_agent", agentID: target.id))
        }

        // The question arrives on the ordinary surface, and the call waits for it.
        try await waitFor { await !core.pendingPermissionRequests().isEmpty }
        let question = try #require(await core.pendingPermissionRequests().first)
        #expect(question.agentID == lead.id)
        #expect(question.toolCall.title.contains("Stop an agent"))

        try await core.answerPermission(
            DaemonAPI.AnswerRequest(permissionID: question.id, optionID: "reject_once"))
        let answer = try await call.value
        #expect(answer.contains("declined"), "and the lead is told, rather than left hanging")
    }

    @Test func alwaysIsNotAskedTwice() async throws {
        let (locations, root) = try temporary()
        let work = try folder(root, "api")
        let core = try await core(locations, seeded: [
            worker(in: work, title: "One", state: .running),
            worker(in: work, title: "Two", state: .running),
        ])
        _ = try await core.addProject(work)
        let lead = try #require(await core.lead(in: work))
        let token = await core.bindTokenForTesting(to: lead.id)
        let all = await core.allAgents().filter { $0.role == .worker }

        let first = Task {
            try await core.callLeadTool(
                DaemonAPI.LeadToolRequest(token: token, tool: "stop_agent", agentID: all[0].id))
        }
        try await waitFor { await !core.pendingPermissionRequests().isEmpty }
        let question = try #require(await core.pendingPermissionRequests().first)
        try await core.answerPermission(
            DaemonAPI.AnswerRequest(permissionID: question.id, optionID: "allow_always"))
        _ = try await first.value

        // The second one goes through without anybody being asked again.
        let answer = try await core.callLeadTool(
            DaemonAPI.LeadToolRequest(token: token, tool: "stop_agent", agentID: all[1].id))
        #expect(answer == "Stopped.")
        #expect(await core.pendingPermissionRequests().isEmpty)
    }

    /// Spin until something becomes true, or give up. The permission question is raised
    /// from inside the call we are waiting on, so there is nothing else to await.
    private func waitFor(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("waited for something that never happened")
    }
}
