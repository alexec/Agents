import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// An agent that ends its turn blocked, and the app carrying it on when the block
/// clears (039).
///
/// What this suite holds is SC-002: every block that clears produces exactly one
/// resume, and none after the person has prompted, stopped or archived the agent. Each
/// test lets everything settle and then counts resumes, rather than stopping at the
/// first one.
@Suite("Blocked agents", .timeLimit(.minutes(1)))
struct BlockedTests {
    /// Which agent each test token speaks for, bound again before every call: a fake
    /// agent's session drops its token when its turn ends. See `HelperAgentTests`.
    private final class Callers: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String: UUID] = [:]
        subscript(token: String) -> UUID? {
            get { lock.withLock { ids[token] } }
            set { lock.withLock { ids[token] = newValue } }
        }
    }
    private let callers = Callers()

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsBlocked-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work.resolvingSymlinksInPath()))
    }

    private func makeCore(_ locations: StoreLocations, _ launcher: FakeLauncher) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        await core.loadFromDisk()
        return core
    }

    /// A turn that lasts until the test opens `gate`, so a test can report while it is
    /// still going however slow the machine.
    private static func held(_ gate: TurnGate) -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.gate = gate
        return script
    }

    /// An agent the person started, with a token that speaks for it.
    private func agent(_ core: DaemonCore, in folder: URL, _ title: String) async throws -> (UUID, String) {
        let id = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: folder, prompt: title))
        let token = UUID().uuidString
        callers[token] = id
        await core.bindAppToken(token, to: id)
        return (id, token)
    }

    /// Agents written straight into the store before the daemon reads it, so a test
    /// about what a report may name does not depend on which runtime starts when.
    private func seeded(_ locations: StoreLocations, _ agents: [Agent]) async throws -> DaemonCore {
        let store = try AgentStore(locations: locations)
        for agent in agents { try await store.save(agent) }
        return try await makeCore(locations, FakeLauncher(script: .init()))
    }

    private func token(_ core: DaemonCore, for id: UUID) async -> String {
        let token = UUID().uuidString
        callers[token] = id
        await core.bindAppToken(token, to: id)
        return token
    }

    private static func finished(_ title: String, in work: URL, _ report: WorkReport? = nil) -> Agent {
        Agent(runtimeID: "claude", cwd: work, title: title, state: .finished, endedReason: .endTurn,
              report: report)
    }

    @discardableResult
    private func finish(_ core: DaemonCore, _ token: String, _ outcome: String, _ message: String,
                        waitingOn: [String]? = nil, minutes: Int? = nil) async throws -> String {
        if let id = callers[token] { await core.bindAppToken(token, to: id) }
        return try await core.finishTurn(.init(token: token, outcome: outcome, message: message,
                                               prompts: [], title: nil, waitingOn: waitingOn,
                                               checkAgainInMinutes: minutes))
    }

    private func refusal(_ body: () async throws -> Void) async -> String? {
        do { try await body(); return nil } catch let error as JSONRPCError { return error.message } catch { return "\(error)" }
    }

    /// The resumes this agent was sent: the app's prompts that say a block cleared or
    /// its time came.
    private func resumes(_ core: DaemonCore, _ id: UUID) async throws -> [String] {
        try await core.transcript(.init(agentID: id, before: nil, limit: 500)).entries.compactMap {
            guard case .userMessage(let text, _, let from) = $0.kind, from == .app,
                  text.hasPrefix("The block you reported has cleared") || text.hasPrefix("The time you asked")
            else { return nil }
            return text
        }
    }

    /// Long enough for anything queued behind a settle to have shown itself.
    private func quiet() async throws { try await Task.sleep(for: .milliseconds(300)) }

    // MARK: US1 — waiting on helpers

    /// The P1 case, whole: one helper reports, one ends silently, and the agent that
    /// waited on both is resumed once, after the second, told how each ended.
    @Test func twoHelpersFinishingGiveOneResumeNamingEach() async throws {
        let (locations, work) = try temporary()
        // The helpers first, so the lead's quick turn — and the question after it —
        // cannot take a helper's held script.
        let firstGate = TurnGate(), secondGate = TurnGate()
        let launcher = FakeLauncher(script: .init(),
                                    then: [Self.held(firstGate), Self.held(secondGate)])
        let core = try await makeCore(locations, launcher)
        let (first, firstToken) = try await agent(core, in: work, "Port the model")
        let (second, _) = try await agent(core, in: work, "Update the tests")
        let (lead, leadToken) = try await agent(core, in: work, "Lead")
        await settled(core, lead)

        let note = try await finish(core, leadToken, "blocked", "Waiting on both helpers.",
                                    waitingOn: [first.uuidString, "update the tests"])
        #expect(note.contains("Blocked"))
        #expect(await core.agent(lead)?.group(wantsEyes: false) == .blocked)
        try await finish(core, firstToken, "done", "Ported.")
        firstGate.open()

        await settled(core, first, "the first helper finished")
        try await quiet()
        #expect(try await resumes(core, lead).isEmpty, "nothing is sent until both have finished")
        let waits = try #require(await core.agent(lead)?.report?.block?.waits)
        #expect(waits.filter { $0.ending != nil }.map(\.agentID) == [first])

        secondGate.open()
        await settled(core, second, "the second helper finished, and was asked how")
        await eventually("the lead was resumed") { (try? await self.resumes(core, lead).count) == 1 }
        await settled(core, lead, "the lead's resumed turn ended")
        try await quiet()
        let sent = try await resumes(core, lead)
        #expect(sent.count == 1)
        #expect(sent.first?.contains("\u{201C}Port the model\u{201D} (id \(first.uuidString)): finished: complete — Ported.") == true)
        #expect(sent.first?.contains("\u{201C}Update the tests\u{201D} (id \(second.uuidString)): finished without saying how it went") == true)
        #expect(sent.first?.contains("You said you were waiting on: Waiting on both helpers.") == true)
    }

    /// Reported mid-turn, with what it named already over by the time its own turn
    /// ends: resumed then, once.
    @Test func aBlockWhoseWaitsClosedBeforeItsTurnEndedIsResumedWhenItEnds() async throws {
        let (locations, work) = try temporary()
        let leadGate = TurnGate(), helperGate = TurnGate()
        let launcher = FakeLauncher(script: .init(), then: [Self.held(leadGate), Self.held(helperGate)])
        let core = try await makeCore(locations, launcher)
        let (lead, leadToken) = try await agent(core, in: work, "Lead")
        let (helper, helperToken) = try await agent(core, in: work, "Helper")
        try await finish(core, leadToken, "blocked", "Waiting on the helper.", waitingOn: [helper.uuidString])
        try await finish(core, helperToken, "done", "Done.")
        helperGate.open()
        await settled(core, helper)
        #expect(await core.agent(lead)?.state == .running, "the lead's own turn is still going")
        leadGate.open()
        await eventually("the lead was resumed") { (try? await self.resumes(core, lead).count) == 1 }
        await settled(core, lead)
        try await quiet()
        #expect(try await resumes(core, lead).count == 1)
    }

    // MARK: Refusals (contract §2)

    @Test func everyRefusalWritesNothingAndSaysWhy() async throws {
        let (locations, work) = try temporary()
        let other = Project.standardize(work.deletingLastPathComponent().appendingPathComponent("other"))
        let lead = Self.finished("Lead", in: work)
        let done = Self.finished("Finished one", in: work,
                                 WorkReport(outcome: .done, message: "All done.", at: Date()))
        let stopped = Agent(runtimeID: "claude", cwd: work, title: "Stopped one", state: .stopped,
                            endedReason: .cancelled)
        let twins = [Agent(runtimeID: "claude", cwd: work, title: "Twin", state: .running),
                     Agent(runtimeID: "claude", cwd: work, title: "twin", state: .running)]
        let elsewhere = Agent(runtimeID: "claude", cwd: other, title: "Elsewhere", state: .running)
        let core = try await seeded(locations, [lead, done, stopped, elsewhere] + twins)
        let token = await token(core, for: lead.id)

        let cases: [([String]?, Int?, String)] = [
            (["Nobody"], nil, "no agent in this project is called"),
            (["Twin"], nil, "could be any of"),
            ([elsewhere.id.uuidString], nil, "is in another project"),
            ([lead.id.uuidString], nil, "you can't wait on yourself"),
            ([stopped.id.uuidString], nil, "has already ended"),
            ([done.id.uuidString], nil, "has already ended (complete — All done.)"),
            (nil, 0, "has to be from 1 to 1440"),
            (nil, 1441, "has to be from 1 to 1440"),
        ]
        for (names, minutes, words) in cases {
            let said = await refusal { try await self.finish(core, token, "blocked", "Waiting.",
                                                             waitingOn: names, minutes: minutes) }
            #expect(said?.contains(words) == true, "\(names ?? []) \(minutes ?? 0): \(said ?? "accepted")")
        }
        let wrongOutcome = await refusal { try await self.finish(core, token, "done", "Done.", waitingOn: ["Twin"]) }
        #expect(wrongOutcome?.contains("only go with blocked") == true)
        #expect(await core.agent(lead.id)?.report == nil, "no refusal wrote anything")
        // The unknown-name refusal lists what it could have meant, by id.
        let unknown = await refusal { try await self.finish(core, token, "blocked", "W.", waitingOn: ["Nobody"]) }
        #expect(unknown?.contains("\(done.id.uuidString): \u{201C}Finished one\u{201D}") == true)
    }

    /// A circle is refused however long it is, and names the agents in it.
    @Test func aCircleIsRefused() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher(script: Self.held(TurnGate()))
        let core = try await makeCore(locations, launcher)
        let (a, aToken) = try await agent(core, in: work, "A")
        let (b, bToken) = try await agent(core, in: work, "B")
        let (_, cToken) = try await agent(core, in: work, "C")
        try await finish(core, aToken, "blocked", "On B.", waitingOn: [b.uuidString])
        try await finish(core, bToken, "blocked", "On C.", waitingOn: ["C"])
        let said = await refusal { try await self.finish(core, cToken, "blocked", "On A.", waitingOn: [a.uuidString]) }
        #expect(said?.contains("would close a circle") == true)
        #expect(said?.contains("\u{201C}A\u{201D} waits on \u{201C}B\u{201D} waits on you") == true)
    }

    /// Waiting on an agent that is itself blocked is allowed: it has not finished.
    @Test func anAgentThatIsItselfBlockedCanBeWaitedOn() async throws {
        let (locations, work) = try temporary()
        let far = Agent(runtimeID: "claude", cwd: work, title: "Far", state: .running)
        let middle = Self.finished("Middle", in: work,
                                   WorkReport(outcome: .blocked, message: "On far.", at: Date(),
                                              block: Block(waits: [Wait(agentID: far.id, nameAtReport: "Far")])))
        let lead = Self.finished("Lead", in: work)
        let core = try await seeded(locations, [far, middle, lead])
        let leadToken = await token(core, for: lead.id)
        try await finish(core, leadToken, "blocked", "On middle.", waitingOn: ["MIDDLE"])
        #expect(await core.agent(lead.id)?.report?.block?.waits.map(\.agentID) == [middle.id])
    }

    // MARK: US3 — the person can unblock it

    @Test func aPersonsPromptEndsTheBlockAndNothingIsSentLater() async throws {
        let (locations, work) = try temporary()
        let helperGate = TurnGate()
        let launcher = FakeLauncher(script: .init(), then: [Self.held(helperGate)])
        let core = try await makeCore(locations, launcher)
        let (helper, helperToken) = try await agent(core, in: work, "Helper")
        let (lead, leadToken) = try await agent(core, in: work, "Lead")
        await settled(core, lead)
        try await finish(core, leadToken, "blocked", "Waiting.", waitingOn: [helper.uuidString])
        try await core.prompt(.init(agentID: lead, text: Block.carryOnPrompt))
        #expect(await core.agent(lead)?.report == nil)
        try await finish(core, helperToken, "done", "Done.")
        helperGate.open()
        await settled(core, helper)
        await settled(core, lead)
        try await quiet()
        #expect(try await resumes(core, lead).isEmpty)
    }

    @Test func stoppingABlockedAgentStopsItAndNothingIsSentLater() async throws {
        let (locations, work) = try temporary()
        let helperGate = TurnGate()
        let launcher = FakeLauncher(script: .init(), then: [Self.held(helperGate)])
        let core = try await makeCore(locations, launcher)
        let (helper, helperToken) = try await agent(core, in: work, "Helper")
        let (lead, leadToken) = try await agent(core, in: work, "Lead")
        await settled(core, lead)
        try await finish(core, leadToken, "blocked", "Waiting.", waitingOn: [helper.uuidString])
        try await core.stop(lead)
        let stopped = try #require(await core.agent(lead))
        #expect(stopped.state == .stopped)
        #expect(stopped.endedReason == .cancelled)
        #expect(stopped.group(wantsEyes: false) == .stopped)
        try await finish(core, helperToken, "done", "Done.")
        helperGate.open()
        await settled(core, helper)
        try await quiet()
        #expect(await core.agent(lead)?.state == .stopped)
        #expect(try await resumes(core, lead).isEmpty)
    }

    @Test func archivingABlockedAgentIsNeverUndoneByAResume() async throws {
        let (locations, work) = try temporary()
        let helperGate = TurnGate()
        let launcher = FakeLauncher(script: .init(), then: [Self.held(helperGate)])
        let core = try await makeCore(locations, launcher)
        let (helper, helperToken) = try await agent(core, in: work, "Helper")
        let (lead, leadToken) = try await agent(core, in: work, "Lead")
        await settled(core, lead)
        try await finish(core, leadToken, "blocked", "Waiting.", waitingOn: [helper.uuidString])
        try await core.archive(lead)
        try await finish(core, helperToken, "done", "Done.")
        helperGate.open()
        await settled(core, helper)
        try await quiet()
        #expect(await core.agent(lead)?.state == .archived)
        #expect(try await resumes(core, lead).isEmpty)
    }

    /// Stopping the agent waited on counts as its ending.
    @Test func aWaitedOnAgentThatIsStoppedClearsTheBlock() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher(script: .init(), then: [Self.held(TurnGate())])
        let core = try await makeCore(locations, launcher)
        let (helper, _) = try await agent(core, in: work, "Helper")
        let (lead, leadToken) = try await agent(core, in: work, "Lead")
        await settled(core, lead)
        try await finish(core, leadToken, "blocked", "Waiting.", waitingOn: [helper.uuidString])
        try await core.stop(helper)
        await eventually("the lead was resumed") { (try? await self.resumes(core, lead).count) == 1 }
        #expect(try await resumes(core, lead).first?.contains("stopped") == true)
    }

    /// FR-018: a resume that cannot start — here, held by the agent's spending limit —
    /// is the person's to fix: the words come back out of the queue, and the agent
    /// reports stuck, with why, under Needs attention.
    @Test func aResumeThatCannotStartGoesToNeedsAttention() async throws {
        let (locations, work) = try temporary()
        try LimitStore(locations: locations).save(CostLimits(perAgent: Cost(amount: 1, currency: "USD")))
        let helper = Agent(runtimeID: "claude", cwd: work, title: "Helper", state: .running)
        var lead = Self.finished("Lead", in: work)
        lead.costToDate = ["USD": 5]
        let core = try await seeded(locations, [helper, lead])
        let leadID = lead.id
        let leadToken = await token(core, for: leadID)
        try await finish(core, leadToken, "blocked", "Waiting on the helper.", waitingOn: [helper.id.uuidString])

        try await core.stop(helper.id)
        await eventually("the lead reports stuck") {
            await core.agent(leadID)?.report?.outcome == .stuck
        }
        let after = try #require(await core.agent(leadID))
        #expect(after.report?.message.hasPrefix("Could not carry on after the block cleared") == true)
        #expect(after.queuedPrompts.isEmpty)
        #expect(after.group(wantsEyes: false) == .needsAttention)
    }

    // MARK: US4 — a time to check again

    @Test func theTimeResumesItOnceOnTheHeartbeat() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher(script: .init())
        let core = try await makeCore(locations, launcher)
        let (lead, leadToken) = try await agent(core, in: work, "Lead")
        await settled(core, lead)
        try await finish(core, leadToken, "blocked", "Waiting on CI for fix-login.", minutes: 25)
        let at = try #require(await core.agent(lead)?.report?.block?.checkAgainAt)

        await core.tickWorkflows(now: at.addingTimeInterval(-60))
        #expect(try await resumes(core, lead).isEmpty)
        await core.tickWorkflows(now: at.addingTimeInterval(1))
        await eventually("the lead was resumed") { (try? await self.resumes(core, lead).count) == 1 }
        await settled(core, lead)
        await core.tickWorkflows(now: at.addingTimeInterval(120))
        try await quiet()
        let sent = try await resumes(core, lead)
        #expect(sent.count == 1)
        #expect(sent.first?.contains("Waiting on CI for fix-login.") == true)
    }

    /// Named nothing and gave no time: only the person moves it.
    @Test func aBlockOnNothingIsNeverResumedByTheApp() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, FakeLauncher(script: .init()))
        let (lead, leadToken) = try await agent(core, in: work, "Lead")
        await settled(core, lead)
        let note = try await finish(core, leadToken, "blocked", "Waiting on a review.")
        #expect(note.contains("until the person carries you on"))
        await core.tickWorkflows(now: Date().addingTimeInterval(86_400 * 2))
        try await quiet()
        #expect(try await resumes(core, lead).isEmpty)
        #expect(await core.agent(lead)?.group(wantsEyes: false) == .blocked)
    }

    // MARK: FR-020 — restarts

    /// A block whose helper ended while the daemon was away, and a resume queued by the
    /// last daemon and never sent: each is sent once, and only once.
    @Test func aRestartSendsWhatWasOwedOnce() async throws {
        let (locations, work) = try temporary()
        let helper = Agent(runtimeID: "claude", cwd: work, title: "Helper", state: .stopped,
                           endedReason: .cancelled)
        let open = Agent(runtimeID: "claude", cwd: work, title: "Open", state: .finished, endedReason: .endTurn,
                         report: WorkReport(outcome: .blocked, message: "On the helper.", at: Date(),
                                            block: Block(waits: [Wait(agentID: helper.id, nameAtReport: "Helper")])))
        var queuedBlock = Block(waits: [Wait(agentID: helper.id, nameAtReport: "Helper",
                                             ending: WaitEnding(at: Date(), how: .archived))])
        queuedBlock.clearedAt = Date()
        queuedBlock.clearedBy = .waits
        var queued = Agent(runtimeID: "claude", cwd: work, title: "Queued", state: .finished, endedReason: .endTurn,
                           report: WorkReport(outcome: .blocked, message: "On the helper.", at: Date(),
                                              block: queuedBlock))
        queued.queuedPrompts = [QueuedPrompt(text: "The block you reported has cleared: resumed before.", from: .app)]
        let store = try AgentStore(locations: locations)
        for agent in [helper, open, queued] { try await store.save(agent) }

        let core = try await makeCore(locations, FakeLauncher(script: .init()))
        await core.resumeBlocksAfterRestart()
        await settled(core, open.id)
        await settled(core, queued.id)
        await core.resumeBlocksAfterRestart()
        try await quiet()
        #expect(try await resumes(core, open.id).count == 1)
        #expect(try await resumes(core, queued.id).count == 1)
    }
}
