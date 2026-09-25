import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// An agent starting, stopping, archiving and listing agents of its own (028).
///
/// What this suite holds is the boundary: the new agent always lands in the caller's
/// own project, a project never holds more than three agents started by agents however
/// the requests arrive, an agent touches only the agents it started, and an agent
/// another agent started has none of it. Every refusal is checked for its words as
/// well as its effect, because the calling agent reads them.
@Suite("Agents started by agents", .timeLimit(.minutes(1)))
struct HelperAgentTests {
    /// Which agent each test token speaks for. A fake agent's turn ends when it likes,
    /// and a session ending drops its token, so every call binds its token again first
    /// — what these tests are about is the tools, not how long a token lives. The same
    /// arrangement as `WorkflowToolTests.call(keepingAlive:)`.
    private final class Callers: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String: UUID] = [:]
        subscript(token: String) -> UUID? {
            get { lock.withLock { ids[token] } }
            set { lock.withLock { ids[token] = newValue } }
        }
    }
    private let callers = Callers()

    private func bound(_ core: DaemonCore, _ token: String) async -> String {
        if let id = callers[token] { await core.bindAppToken(token, to: id) }
        return token
    }

    /// A tool call made with the token bound again first — and made again if the
    /// caller's session ended in the moment between the two, which a fake agent's
    /// quick turn can do under load. Only for a token that does speak for an agent:
    /// a test about a token that never did still sees its refusal.
    private func calling<T>(_ core: DaemonCore, _ token: String,
                            _ body: (String) async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body(await bound(core, token))
            } catch let error as JSONRPCError
                        where error.code == DaemonAPI.Failure.noSuchAgent
                        && error.message.hasPrefix("That conversation is not open")
                        && callers[token] != nil && attempt < 5 {
                attempt += 1
            }
        }
    }
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsHelpers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StoreLocations(root: root), root.resolvingSymlinksInPath())
    }

    private func project(_ root: URL, _ name: String = "api") throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Project.standardize(url)
    }

    private func makeCore(_ locations: StoreLocations, _ launcher: FakeLauncher) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        await core.loadFromDisk()
        return core
    }

    /// An agent the person started, and a token that speaks for it.
    private func caller(_ core: DaemonCore, in folder: URL,
                        title: String = "Lead") async throws -> (UUID, String) {
        let id = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: folder,
                                                             prompt: title))
        let token = UUID().uuidString
        callers[token] = id
        await core.bindAppToken(token, to: id)
        return (id, token)
    }

    private func start(_ core: DaemonCore, _ token: String, _ prompt: String = "Count the files",
                       runtime: String? = nil) async throws -> UUID {
        try await calling(core, token) { t in try await core.startHelper(.init(token: t, prompt: prompt,
                                         runtime: runtime)) }.agentID
    }

    private func refusal(_ body: () async throws -> Void) async -> JSONRPCError? {
        do { try await body(); return nil } catch let error as JSONRPCError { return error } catch { return nil }
    }

    private func notes(_ core: DaemonCore, _ id: UUID) async throws -> [String] {
        try await core.transcript(.init(agentID: id, before: nil, limit: 200)).entries.compactMap {
            if case .runtimeNote(let text) = $0.kind { return text }
            return nil
        }
    }

    // MARK: Starting (US1)

    @Test func aStartedAgentLandsInTheCallersProjectMarkedAsTheirs() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (lead, token) = try await caller(core, in: work)

        let started = try await calling(core, token) { t in try await core.startHelper(.init(token: t, prompt: "Count the files")) }
        let helper = try #require(await core.agent(started.agentID))

        #expect(Project.standardize(helper.cwd) == work)
        #expect(helper.startedByAgent == lead)
        #expect(started.note.contains("(id \(started.agentID.uuidString))"))
        #expect(started.note.contains("1 of 3 places in this project are now in use."))
    }

    @Test func itsChatOpensWithWhoStartedIt() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (_, token) = try await caller(core, in: work, title: "Tidy the imports")
        let id = try await start(core, token)

        let entries = try await core.transcript(.init(agentID: id, before: nil, limit: 200)).entries
        guard case .runtimeNote(let first) = entries.first?.kind else {
            Issue.record("the first entry was \(String(describing: entries.first?.kind))")
            return
        }
        #expect(first == "Started by \u{201C}Tidy the imports\u{201D}.")
        let prompted = entries.contains {
            if case .userMessage(let text, _, _) = $0.kind { return text == "Count the files" }
            return false
        }
        #expect(prompted, "and it was given the prompt")
    }

    @Test func aTokenThatMeansNothingStartsNothing() async throws {
        let (locations, root) = try temporary()
        _ = try project(root)
        let core = try await makeCore(locations, FakeLauncher())

        let error = await refusal { _ = try await start(core, "not-a-token") }
        #expect(error?.message.contains("That conversation is not open any more") == true)
        #expect(await core.allAgents().isEmpty)
    }

    @Test func anEmptyPromptStartsNothing() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (_, token) = try await caller(core, in: work)

        let error = await refusal { _ = try await start(core, token, "   ") }
        #expect(error?.message == "Nothing was started: say what the agent is to do.")
        #expect(await core.allAgents().count == 1)
    }

    @Test func aRuntimeThisBuildDoesNotKnowStartsNothingAndSaysWhatItKnows() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (_, token) = try await caller(core, in: work)

        let error = await refusal { _ = try await start(core, token, runtime: "abacus") }
        let message = error?.message ?? ""
        #expect(message.hasPrefix("Nothing was started: "))
        #expect(message.contains("abacus"))
        #expect(message.contains(RuntimeCatalog.builtIn[0].id))
        #expect(await core.allAgents().count == 1, "no agent left behind")
        #expect(await core.reservedStarts.values.allSatisfy { $0 == 0 }, "and its place given back")
    }

    // MARK: The limits (US2)

    @Test func aFourthIsRefusedAndTheThreeAreNamed() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (_, first) = try await caller(core, in: work)
        let (_, second) = try await caller(core, in: work, title: "Other")
        _ = try await start(core, first, "Alpha")
        _ = try await start(core, second, "Beta")
        _ = try await start(core, first, "Gamma")

        let error = await refusal { _ = try await start(core, second, "Delta") }
        let message = error?.message ?? ""
        #expect(error?.code == DaemonAPI.Failure.notYours)
        #expect(message.hasPrefix("Nothing was started: this project already has 3 agents started by agents"))
        for name in ["Alpha", "Beta", "Gamma"] { #expect(message.contains(name), "names \(name)") }
        #expect(await core.allAgents().count == 5)
    }

    @Test func archivingOneGivesItsPlaceBack() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (_, token) = try await caller(core, in: work)
        let alpha = try await start(core, token, "Alpha")
        _ = try await start(core, token, "Beta")
        _ = try await start(core, token, "Gamma")
        // Settled for good: finished, asked how its work went (a fake agent never
        // says), and let go. Archiving before that ask lands would see the ask's
        // prompt pick the agent back up, which is not what this test is about.
        _ = await eventually("Alpha settled") {
            let agent = await core.agent(alpha)
            let released = await core.live[alpha] == nil
            return agent?.outcomeAsked == true && agent?.state.holdsRuntime == false && released
        }

        try await core.archive(alpha)   // by the person
        _ = try await start(core, token, "Delta")

        #expect(await core.allAgents().filter { $0.startedByAgent != nil }.count == 4)
    }

    @Test func anotherProjectsAgentsTakeNoPlaceHere() async throws {
        let (locations, root) = try temporary()
        let here = try project(root)
        let there = try project(root, "web")
        let core = try await makeCore(locations, FakeLauncher())
        let (_, elsewhere) = try await caller(core, in: there)
        for name in ["A", "B", "C"] { _ = try await start(core, elsewhere, name) }
        let (_, token) = try await caller(core, in: here)

        _ = try await start(core, token)
    }

    /// SC-002. The starts overlap for real: every handshake is held long enough for all
    /// four calls to have been made before the first session exists.
    @Test func fourAtOnceMakeExactlyThree() async throws {
        for _ in 0..<10 {
            let (locations, root) = try temporary()
            let work = try project(root)
            var slow = FakeACPAgent.Script()
            slow.handshakeDelay = .milliseconds(150)
            let core = try await makeCore(locations, FakeLauncher(script: slow))
            let (_, token) = try await caller(core, in: work)

            let results = await withTaskGroup(of: Bool.self) { group in
                for index in 0..<4 {
                    group.addTask {
                        (try? await calling(core, token) { t in try await core.startHelper(.init(token: t, prompt: "Part \(index)")) }) != nil
                    }
                }
                return await group.reduce(into: [Bool]()) { $0.append($1) }
            }

            #expect(results.filter { $0 }.count == 3)
            #expect(await core.allAgents().filter { $0.startedByAgent != nil }.count == 3)
            #expect(await core.reservedStarts[work, default: 0] == 0)
        }
    }

    @Test func anAgentAnotherAgentStartedCannotStartOne() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (_, token) = try await caller(core, in: work)
        let helper = try await start(core, token)
        let helperToken = UUID().uuidString
        callers[helperToken] = helper
        await core.bindAppToken(helperToken, to: helper)

        let error = await refusal { _ = try await start(core, helperToken) }
        #expect(error?.code == DaemonAPI.Failure.notYours)
        #expect(error?.message.contains("an agent that another agent started cannot") == true)
    }

    /// Checked on what the runtime was actually handed, both when it was made and when
    /// it was picked back up, rather than on anything the daemon says about itself.
    @Test func anAgentAnotherAgentStartedIsNeverOfferedTheTools() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let launcher = FakeLauncher()
        let core = try await makeCore(locations, launcher)
        let (_, token) = try await caller(core, in: work)
        let callerArgs = await launcher.lastAgent?.newSessionParams?["mcpServers"]?.arrayValue?
            .first?["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(!callerArgs.contains(DaemonCore.noAgentToolsFlag), "the person's agent has them")

        let helper = try await start(core, token)
        let madeArgs = await launcher.lastAgent?.newSessionParams?["mcpServers"]?.arrayValue?
            .first?["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(madeArgs.contains(DaemonCore.noAgentToolsFlag))

        _ = await eventually("the helper's turn ended and its runtime went") {
            let settled = await core.agent(helper)?.state.holdsRuntime == false
            let released = await core.live[helper] == nil
            return settled && released
        }
        try await core.prompt(DaemonAPI.PromptRequest(agentID: helper, text: "And again"))
        // The helper's own session, found by its id among every launch rather than
        // assumed to be the newest: the lead is picked back up too, to be asked how
        // its work went, and under load that can land after this.
        let sessionID = await core.agent(helper)?.runtimeSessionID
        let resumedArgs = await eventuallySome("it was picked back up") { () async -> [String]? in
            for agent in launcher.allAgents.reversed() {
                guard let params = await agent.continuedSessionParams,
                      params["sessionId"]?.stringValue == sessionID else { continue }
                return params["mcpServers"]?.arrayValue?.first?["args"]?.arrayValue?
                    .compactMap(\.stringValue)
            }
            return nil
        } ?? []
        #expect(resumedArgs.contains(DaemonCore.noAgentToolsFlag), "\(resumedArgs)")
    }

    @Test func aWorkflowsAgentMayStartOne() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (lead, token) = try await caller(core, in: work)
        if var agent = await core.agent(lead) {
            agent.startedByWorkflow = "nightly"
            await core.changed(agent)
        }

        _ = try await start(core, token)
    }

    @Test func whoStartedItAndTheCountSurviveARestart() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let first = try await makeCore(locations, FakeLauncher())
        let (lead, token) = try await caller(first, in: work)
        let helper = try await start(first, token)
        _ = await eventually("the helper was saved settled") {
            await first.agent(helper)?.state.holdsRuntime == false
        }
        _ = await eventually("the lead was saved settled") {
            await first.agent(lead)?.state.holdsRuntime == false
        }

        let second = try await makeCore(locations, FakeLauncher())
        #expect(await second.agent(helper)?.startedByAgent == lead)
        #expect(HelperLimit.placesInUse(in: work, agents: await second.allAgents()) == 1)
    }

    /// A workflow's agent that starts one does not reset the chain: the one it starts
    /// is as deep as a step taken by the workflow's agent itself would be.
    @Test func anAgentStartedInsideAChainCarriesItsDepth() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (lead, token) = try await caller(core, in: work)
        let run = WorkflowRun(workflowID: "nightly", folder: work, trigger: .agentFinished,
                              depth: 2, agentID: lead)
        await core.setWorkflowRunForTesting(run)
        if var agent = await core.agent(lead) {
            agent.startedByRun = run.id
            await core.changed(agent)
        }

        let helper = try await start(core, token)

        #expect(await core.workflowChainDepth(causedBy: lead) == 3)
        #expect(await core.workflowChainDepth(causedBy: helper) == 3)
    }

    /// The run a helper's starter was in can end long before the helper does. Its
    /// depth was taken when it was made, so a helper finishing afterwards does not
    /// begin the chain again at zero.
    @Test func aHelperKeepsItsDepthOnceItsStartersRunIsOver() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (lead, token) = try await caller(core, in: work)
        let run = WorkflowRun(workflowID: "nightly", folder: work, trigger: .agentFinished,
                              depth: 2, agentID: lead)
        await core.setWorkflowRunForTesting(run)
        if var agent = await core.agent(lead) {
            agent.startedByRun = run.id
            await core.changed(agent)
        }
        let helper = try await start(core, token)

        await core.clearWorkflowRunsForTesting()

        #expect(await core.workflowChainDepth(causedBy: lead) == 0, "the lead's run is over")
        #expect(await core.workflowChainDepth(causedBy: helper) == 3, "the helper's depth is not")
        #expect(await core.agent(helper)?.chainDepth == 3, "and it is on the record")
    }

    // MARK: Stopping and archiving (US3)

    private func longTurns() -> FakeLauncher {
        var script = FakeACPAgent.Script()
        script.turnDelay = .seconds(5)
        return FakeLauncher(script: script)
    }

    @Test func stoppingOneItStartedSaysWhoStoppedIt() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, longTurns())
        let (_, token) = try await caller(core, in: work, title: "Lead")
        let helper = try await start(core, token)
        _ = await eventually("the helper is working") { await core.agent(helper)?.state == .running }

        let note = try await calling(core, token) { t in try await core.stopHelper(.init(token: t, agentID: helper.uuidString)) }

        let stopped = try #require(await core.agent(helper))
        #expect(stopped.state == .stopped)
        #expect(stopped.endedReason == .stoppedByAgent)
        #expect(note.hasPrefix("Stopped "))
        #expect(try await notes(core, helper).contains("\u{201C}Lead\u{201D} stopped this agent."))
    }

    @Test func stoppingOneThatHasAlreadyStoppedChangesNothing() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (_, token) = try await caller(core, in: work)
        let helper = try await start(core, token)
        _ = await eventually("the helper finished") { await core.agent(helper)?.state == .finished }

        let note = try await calling(core, token) { t in try await core.stopHelper(.init(token: t, agentID: helper.uuidString)) }

        #expect(note.hasSuffix("had already stopped; nothing changed."))
        #expect(await core.agent(helper)?.state == .finished)
    }

    @Test func archivingOneStopsItFirstAndGivesThePlaceBack() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, longTurns())
        let (_, token) = try await caller(core, in: work)
        let helper = try await start(core, token)
        _ = await eventually("the helper is working") { await core.agent(helper)?.state == .running }

        let note = try await calling(core, token) { t in try await core.archiveHelper(.init(token: t, agentID: helper.uuidString)) }

        let archived = try #require(await core.agent(helper))
        #expect(archived.state == .archived)
        #expect(archived.archivedReason == .byAgent)
        #expect(archived.endedReason == .stoppedByAgent)
        #expect(note.hasSuffix("0 of 3 places in this project are now in use."))
    }

    @Test func anArchivedOneIsSaidToBeArchived() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (_, token) = try await caller(core, in: work)
        let helper = try await start(core, token, "Alpha")
        _ = await eventually("settled") { await core.agent(helper)?.state.holdsRuntime == false }
        try await core.archive(helper)

        let error = await refusal { _ = try await calling(core, token) { t in try await core.stopHelper(.init(token: t, agentID: helper.uuidString)) } }
        #expect(error?.message == "Nothing changed: \u{201C}Alpha\u{201D} is already archived.")
    }

    /// SC-003. Each refusal changes nothing, anywhere.
    @Test func everyAgentThatIsNotItsOwnIsRefusedAndNothingMoves() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, longTurns())
        let (lead, token) = try await caller(core, in: work)
        let (other, otherToken) = try await caller(core, in: work, title: "Other")
        let persons = other
        let othersHelper = try await start(core, otherToken)
        let workflows = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: work,
                                                                    prompt: "Nightly"))
        if var agent = await core.agent(workflows) {
            agent.startedByWorkflow = "nightly"
            await core.changed(agent)
        }
        let before = await core.allAgents().map { "\($0.id) \($0.state) \(String(describing: $0.endedReason))" }.sorted()

        let cases: [(String, String)] = [
            (lead.uuidString, "Nothing changed: an agent cannot stop itself."),
            (persons.uuidString, "Nothing changed: you can only stop or archive agents you started."),
            (workflows.uuidString, "Nothing changed: you can only stop or archive agents you started."),
            (othersHelper.uuidString, "Nothing changed: you can only stop or archive agents you started."),
            ("not-an-id", "Nothing changed: there is no agent with that id."),
            (UUID().uuidString, "Nothing changed: there is no agent with that id."),
        ]
        for (target, expected) in cases {
            let stopped = await refusal { _ = try await calling(core, token) { t in try await core.stopHelper(.init(token: t, agentID: target)) } }
            #expect(stopped?.message == expected, "stop \(target)")
            let archived = await refusal { _ = try await calling(core, token) { t in try await core.archiveHelper(.init(token: t, agentID: target)) } }
            #expect(archived?.message == expected.replacingOccurrences(of: "cannot stop itself",
                                                                        with: "cannot archive itself"),
                    "archive \(target)")
        }

        let after = await core.allAgents().map { "\($0.id) \($0.state) \(String(describing: $0.endedReason))" }.sorted()
        #expect(before == after)
    }

    // MARK: Listing (US4)

    @Test func listingShowsOnlyItsOwnWithStateAndTheCount() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (_, token) = try await caller(core, in: work)
        let (_, otherToken) = try await caller(core, in: work, title: "Other")
        let mine = try await start(core, token, "Alpha")
        let theirs = try await start(core, otherToken, "Beta")
        _ = await eventually("Alpha finished") { await core.agent(mine)?.state == .finished }

        let list = try await calling(core, token) { t in try await core.listHelpers(.init(token: t)) }

        let lines = list.split(separator: "\n").map(String.init)
        #expect(lines.first == "2 of 3 places in this project are in use.")
        #expect(list.contains("- \(mine.uuidString): \u{201C}Alpha\u{201D} — finished"))
        #expect(!list.contains(theirs.uuidString))
    }

    @Test func listingWithNoneSaysSo() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (_, token) = try await caller(core, in: work)

        #expect(try await calling(core, token) { t in try await core.listHelpers(.init(token: t)) }
                == "You have not started any agents that are still here. 0 of 3 places in this project are in use.")
    }
}

extension DaemonCore {
    /// A run in flight, put there directly: what the chain-depth test is about is how
    /// deep an agent's helper is, not how a workflow comes to be running.
    func setWorkflowRunForTesting(_ run: WorkflowRun) {
        workflowRuns[run.id.uuidString] = run
    }

    func clearWorkflowRunsForTesting() {
        workflowRuns.removeAll()
    }
}
