import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// An agent starting, stopping, archiving and listing agents of its own (028).
///
/// What this suite holds is the boundary: the new agent always lands in the caller's
/// own project, a project never holds more agents started by agents than its two limits
/// allow however the requests arrive, an agent touches only the agents it started, and an agent
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

    /// A helper is told who started it, by title, so it names that agent the same way
    /// (#121), and the person by the same name its lead was given.
    @Test func aHelpersBriefingNamesWhoStartedIt() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let launcher = FakeLauncher()
        let core = try await makeCore(locations, launcher)
        _ = try await core.setPerson(PersonSettings(name: "Sam"))
        let (lead, token) = try await caller(core, in: work)

        let helper = try await start(core, token)
        @Sendable func briefings() async -> [String] {
            var texts: [String] = []
            for agent in launcher.allAgents {
                if let text = await agent.promptContent?.arrayValue?.last?["text"]?.stringValue { texts.append(text) }
            }
            return texts
        }
        await eventually("the helper was briefed") { await briefings().contains { $0.contains(", started by") } }
        let told = try #require(await briefings().first { $0.contains(", started by") })
        // By the lead's title as it stands, or "another agent" while it has none.
        let starter = LeaseWords.agentName(await core.agent(lead)?.title)
        #expect(told.contains("You are Claude, started by \(starter), and I am Sam"))
        #expect(await core.agent(helper)?.startedByAgent == lead)
    }

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
        #expect(started.note.contains("This project now has "))
        #expect(started.note.contains(" of 3 running, 1 of 5 not archived."))
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
        try #require(!RuntimeCatalog.builtIn.isEmpty)
        #expect(message.contains(RuntimeCatalog.defaultRuntime.id))
        #expect(await core.allAgents().count == 1, "no agent left behind")
        #expect(await core.reservedStarts.values.allSatisfy { $0 == 0 }, "and its place given back")
    }

    // MARK: Its permission mode

    /// A runtime that offers a default and a plan mode, and starts in the default.
    private static let modes = FakeACPAgent.Script(configOptions: [
        ConfigOption(id: "mode", name: "Mode", category: "mode", type: "select",
                     currentValue: .string("default"),
                     options: [ConfigChoice(value: .string("default"), name: "Default"),
                               ConfigChoice(value: .string("plan"), name: "Plan")]),
    ])

    /// The caller, moved into plan mode the way the person moves it.
    private func callerInPlanMode(_ core: DaemonCore, in folder: URL) async throws -> (UUID, String) {
        let (lead, token) = try await caller(core, in: folder)
        await eventually("the caller heard what its runtime offers") {
            await !(core.agent(lead)?.advertisedOptions.isEmpty ?? true)
        }
        _ = try await core.setOption(.init(agentID: lead, optionID: "mode", value: .string("plan")))
        return (lead, token)
    }

    @Test func aStartedAgentTakesTheModeItsStarterIsIn() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher(script: Self.modes))
        let (_, token) = try await callerInPlanMode(core, in: work)

        let id = try await start(core, token)

        let helper = try #require(await core.agent(id))
        #expect(helper.startOptions.values["mode"] == .string("plan"))
    }

    @Test func aStricterModeItNamesIsTheOneItGets() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher(script: Self.modes))
        let (lead, token) = try await caller(core, in: work)
        await eventually("the caller heard what its runtime offers") {
            await !(core.agent(lead)?.advertisedOptions.isEmpty ?? true)
        }

        let id = try await calling(core, token) { t in
            try await core.startHelper(.init(token: t, prompt: "Count the files", permissionMode: "plan"))
        }.agentID

        #expect(try #require(await core.agent(id)).startOptions.values["mode"] == .string("plan"))
    }

    /// The way round the person's choice this closes: an agent kept to planning
    /// starting one that may edit, and handing it the work.
    @Test func aLooserModeItNamesIsRefused() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher(script: Self.modes))
        let (_, token) = try await callerInPlanMode(core, in: work)

        let error = await refusal {
            _ = try await calling(core, token) { t in
                try await core.startHelper(.init(token: t, prompt: "Count the files", permissionMode: "default"))
            }
        }
        let message = error?.message ?? ""
        #expect(error?.code == JSONRPCError.invalidParams)
        #expect(message.hasPrefix("Nothing was started: default would let it do more without asking"))
        #expect(message.contains("Name no mode and it takes yours"))
        #expect(await core.allAgents().count == 1, "no agent left behind")
    }

    @Test func onAnotherRuntimeItStartsAsThatRuntimeStarts() async throws {
        // A mode is a runtime's own word; the same word elsewhere is not the same promise.
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher(script: Self.modes))
        let (lead, _) = try await callerInPlanMode(core, in: work)
        let caller = try #require(await core.agent(lead))

        #expect(await core.inheritedMode(from: caller, runtime: nil) == "plan")
        #expect(await core.inheritedMode(from: caller, runtime: "grok") == nil)
    }

    // MARK: The limits (US2, #64)

    /// The person lets as many run as may be kept, so a test about the not-archived
    /// limit is not cut short by the running one while fake turns are still going.
    private func runningUpToFive(_ core: DaemonCore, _ folder: URL) async throws {
        _ = try await core.setHelperLimits(.init(folder: folder, limits: HelperLimits(running: 5)))
    }

    /// Past the not-archived limit a start queues (#362); past the queue too, it is
    /// refused, naming both limits and the agents holding them.
    @Test func aSixthIsQueuedAndASeventhPastTheQueueIsRefused() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (_, first) = try await caller(core, in: work)
        let (_, second) = try await caller(core, in: work, title: "Other")
        _ = try await core.setHelperLimits(.init(folder: work, limits: HelperLimits(running: 5, queued: 1)))
        _ = try await start(core, first, "Alpha")
        _ = try await start(core, second, "Beta")
        _ = try await start(core, first, "Gamma")
        _ = try await start(core, second, "Delta")
        _ = try await start(core, first, "Epsilon")

        let queued = try await calling(core, second) { t in try await core.startHelper(.init(token: t, prompt: "Zeta")) }
        #expect(queued.note.hasPrefix("Queued \u{201C}Zeta\u{201D} (id \(queued.agentID.uuidString)), 1st in this project's queue: "
                                      + "This project already has 5 of 5 agents started by agents not yet archived"))
        #expect(queued.note.hasSuffix(", 1 of 1 queued."))
        #expect(await core.agent(queued.agentID)?.state == .queued)

        let error = await refusal { _ = try await start(core, first, "Eta") }
        let message = error?.message ?? ""
        #expect(error?.code == DaemonAPI.Failure.notYours)
        #expect(message.hasPrefix("Nothing was started: this project already has 5 of 5 agents started by agents not yet archived"))
        #expect(message.contains("Archive one of yours with archive_agent once its work is merged or abandoned, "
                                 + "or ask the person to archive one, to free that place."))
        #expect(message.contains(" And its queue is full too: 1 of 1 agents queued — \u{201C}Zeta\u{201D}."))
        #expect(message.hasSuffix("The person sets these limits in Project Settings."))
        for name in ["Alpha", "Beta", "Gamma", "Delta", "Epsilon"] { #expect(message.contains(name), "names \(name)") }
        #expect(await core.allAgents().count == 8)
    }

    @Test func archivingOneGivesItsPlaceBack() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (_, token) = try await caller(core, in: work)
        try await runningUpToFive(core, work)
        let alpha = try await start(core, token, "Alpha")
        _ = try await start(core, token, "Beta")
        _ = try await start(core, token, "Gamma")
        _ = try await start(core, token, "Delta")
        _ = try await start(core, token, "Epsilon")
        // Settled for good: finished, its ending accounted for (a fake agent never
        // says, so the app works it out), and let go.
        _ = await eventually("Alpha settled") {
            let agent = await core.agent(alpha)
            let released = await core.live[alpha] == nil
            return agent?.report != nil && agent?.state.holdsRuntime == false && released
        }

        try await core.archive(alpha)   // by the person
        _ = try await start(core, token, "Zeta")

        #expect(await core.allAgents().filter { $0.startedByAgent != nil }.count == 6)
    }

    @Test func anotherProjectsAgentsTakeNoPlaceHere() async throws {
        let (locations, root) = try temporary()
        let here = try project(root)
        let there = try project(root, "web")
        let core = try await makeCore(locations, FakeLauncher())
        let (_, elsewhere) = try await caller(core, in: there)
        try await runningUpToFive(core, there)
        for name in ["A", "B", "C", "D", "E"] { _ = try await start(core, elsewhere, name) }
        let (_, token) = try await caller(core, in: here)

        _ = try await start(core, token)
    }

    /// SC-002. The starts overlap for real: every handshake is held long enough for all
    /// six calls to have been made before the first session exists.
    @Test func sixAtOnceMakeExactlyFive() async throws {
        for _ in 0..<10 {
            let (locations, root) = try temporary()
            let work = try project(root)
            var slow = FakeACPAgent.Script()
            slow.handshakeDelay = .milliseconds(150)
            let core = try await makeCore(locations, FakeLauncher(script: slow))
            let (_, token) = try await caller(core, in: work)
            try await runningUpToFive(core, work)

            let results = await withTaskGroup(of: Bool.self) { group in
                for index in 0..<6 {
                    group.addTask {
                        (try? await calling(core, token) { t in try await core.startHelper(.init(token: t, prompt: "Part \(index)")) }) != nil
                    }
                }
                return await group.reduce(into: [Bool]()) { $0.append($1) }
            }

            // Five take a place and the sixth queues (#362).
            #expect(results.filter { $0 }.count == 6)
            let helpers = await core.allAgents().filter { $0.startedByAgent != nil }
            #expect(helpers.filter { $0.state != .queued }.count == 5)
            #expect(helpers.filter { $0.state == .queued }.count == 1)
            #expect(await core.reservedStarts[work, default: 0] == 0)
            #expect(await core.reservedQueue[work, default: 0] == 0)
        }
    }

    /// The reserved-start race against the running limit: every start overlaps, so
    /// each is weighed with the others' reservations and none has made its agent yet.
    @Test func sixAtOnceRunExactlyThree() async throws {
        for _ in 0..<10 {
            let (locations, root) = try temporary()
            let work = try project(root)
            var slow = FakeACPAgent.Script()
            slow.handshakeDelay = .milliseconds(150)
            slow.turnDelay = .seconds(5)
            let core = try await makeCore(locations, FakeLauncher(script: slow))
            let (_, token) = try await caller(core, in: work)

            let results = await withTaskGroup(of: String?.self) { group in
                for index in 0..<6 {
                    group.addTask {
                        do {
                            _ = try await calling(core, token) { t in try await core.startHelper(.init(token: t, prompt: "Part \(index)")) }
                            return nil
                        } catch let error as JSONRPCError { return error.message } catch { return "\(error)" }
                    }
                }
                return await group.reduce(into: [String?]()) { $0.append($1) }
            }

            // Three run and three queue (#362); none is refused.
            #expect(results.allSatisfy { $0 == nil }, "\(results)")
            let helpers = await core.allAgents().filter { $0.startedByAgent != nil }
            #expect(helpers.filter { $0.state.holdsRuntime }.count == 3)
            #expect(helpers.filter { $0.state == .queued }.count == 3)
            #expect(await core.reservedStarts[work, default: 0] == 0)
        }
    }

    /// A fourth queues behind the three running (#362), spawning nothing; with the queue
    /// full, a fifth is refused naming the three.
    @Test func aFourthRunningIsQueuedAndOnePastTheQueueIsRefused() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let gate = TurnGate()
        defer { gate.open() }
        let launcher = heldTurns(gate)
        let core = try await makeCore(locations, launcher)
        let (_, token) = try await caller(core, in: work)
        _ = try await core.setHelperLimits(.init(folder: work, limits: HelperLimits(queued: 1)))
        for name in ["Alpha", "Beta", "Gamma"] { _ = try await start(core, token, name) }
        let spawned = launcher.allAgents.count

        let queued = try await calling(core, token) { t in try await core.startHelper(.init(token: t, prompt: "Delta")) }
        #expect(queued.note.contains("This project already has 3 of 3 agents started by agents running"))
        #expect(queued.note.contains("It starts by itself, oldest first"))
        #expect(queued.note.hasSuffix("This project now has 3 of 3 running, 3 of 5 not archived, 1 of 1 queued."))
        let delta = try #require(await core.agent(queued.agentID))
        #expect(delta.state == .queued)
        #expect(delta.group(wantsEyes: false) == .waiting)
        #expect(delta.queuedPrompts.map(\.text) == ["Delta"])
        #expect(launcher.allAgents.count == spawned, "a queued agent spawns nothing")

        let error = await refusal { _ = try await start(core, token, "Epsilon") }
        let message = error?.message ?? ""
        #expect(error?.code == DaemonAPI.Failure.notYours)
        #expect(message.hasPrefix("Nothing was started: this project already has 3 of 3 agents started by agents running"))
        for name in ["Alpha", "Beta", "Gamma", "Delta"] { #expect(message.contains(name), "names \(name)") }
        #expect(message.contains("park_agent or stop_agent"))
        #expect(!message.contains("not yet archived"), "only the limit it would break")
        #expect(await core.allAgents().filter { $0.startedByAgent != nil }.count == 4)
    }

    /// First in, first out (#362): stopping a running one starts the oldest queued, and
    /// the next stays queued, now first.
    @Test func whenOneStopsTheOldestQueuedStarts() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let gate = TurnGate()
        defer { gate.open() }
        let core = try await makeCore(locations, heldTurns(gate))
        let (_, token) = try await caller(core, in: work)
        _ = try await core.setHelperLimits(.init(folder: work, limits: HelperLimits(running: 1)))
        let alpha = try await start(core, token, "Alpha")
        let beta = try await start(core, token, "Beta")
        let gamma = try await start(core, token, "Gamma")
        #expect(await core.agent(beta)?.state == .queued)
        #expect(await core.agent(gamma)?.state == .queued)
        let listed = try await calling(core, token) { t in try await core.listHelpers(.init(token: t)) }
        #expect(listed.contains("\u{201C}Beta\u{201D} — queued (position 1)"))
        #expect(listed.contains("\u{201C}Gamma\u{201D} — queued (position 2)"))

        _ = try await calling(core, token) { t in try await core.stopHelper(.init(token: t, agentID: alpha.uuidString)) }

        await eventually("Beta started from the queue") { await core.agent(beta)?.state.holdsRuntime == true }
        let started = try #require(await core.agent(beta))
        #expect(started.queuedStart == nil)
        #expect(started.startedByAgent != nil)
        #expect(await core.agent(gamma)?.state == .queued)
        #expect(HelperLimit.queuePosition(of: try #require(await core.agent(gamma)),
                                          among: await core.allAgents()) == 1)
        #expect(try await notes(core, beta).contains { $0.hasPrefix("Queued by ") })
    }

    /// Stop and archive take a queued one off the queue (#362); it never starts.
    @Test func stoppingOrArchivingAQueuedOneTakesItOffTheQueue() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let gate = TurnGate()
        defer { gate.open() }
        let core = try await makeCore(locations, heldTurns(gate))
        let (_, token) = try await caller(core, in: work, title: "Lead")
        _ = try await core.setHelperLimits(.init(folder: work, limits: HelperLimits(running: 1)))
        _ = try await start(core, token, "Alpha")
        let beta = try await start(core, token, "Beta")
        let gamma = try await start(core, token, "Gamma")

        let stopped = try await calling(core, token) { t in try await core.stopHelper(.init(token: t, agentID: beta.uuidString)) }
        #expect(stopped.hasPrefix("Took \u{201C}Beta\u{201D} off the queue; it will not start."))
        let beta2 = try #require(await core.agent(beta))
        #expect(beta2.state == .stopped)
        #expect(beta2.endedReason == .stoppedByAgent)
        #expect(try await notes(core, beta).contains("\u{201C}Lead\u{201D} took this agent off the queue before it started."))

        _ = try await calling(core, token) { t in try await core.archiveHelper(.init(token: t, agentID: gamma.uuidString)) }
        let gamma2 = try #require(await core.agent(gamma))
        #expect(gamma2.state == .archived)
        #expect(gamma2.endedReason == .stoppedByAgent)
        #expect(HelperLimit.queue(in: work, agents: await core.allAgents()).isEmpty)
    }

    /// The queue is on disk (#362): a daemon started again finds it, and starts it once
    /// there is a place.
    @Test func aQueuedOneSurvivesARestartAndStartsWhenThereIsAPlace() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let first = try await makeCore(locations, FakeLauncher())
        let (lead, token) = try await caller(first, in: work)
        _ = try await first.setHelperLimits(.init(folder: work, limits: HelperLimits(running: 1, notArchived: 1)))
        let alpha = try await settledHelper(first, token, "Alpha")
        let beta = try await calling(first, token) { t in
            try await first.startHelper(.init(token: t, prompt: "Beta"))
        }.agentID
        #expect(await first.agent(beta)?.state == .queued)
        _ = alpha

        // Room for one more, written into the project's file while no daemon looks.
        _ = try ProjectConfig.setHelperLimits(HelperLimits(running: 1, notArchived: 2), in: work)
        let second = try await makeCore(locations, FakeLauncher())
        let found = try #require(await second.agent(beta))
        #expect(found.state == .queued)
        #expect(found.startedByAgent == lead)
        #expect(found.queuedStart != nil)

        await second.checkEveryQueue()
        await eventually("Beta started after the restart") { await second.agent(beta)?.state != .queued }
        #expect(await second.agent(beta)?.startedByAgent == lead)
    }

    /// A blocked helper the app will carry on by itself holds a running place; a lead
    /// parking it gives that place back, and its not-archived place stays taken.
    @Test func aWaitingHelperRunsUntilItsLeadParksIt() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (_, token) = try await caller(core, in: work)
        var helpers: [UUID] = []
        for name in ["Alpha", "Beta", "Gamma"] {
            let id = try await start(core, token, name)
            helpers.append(id)
            _ = await eventually("\(name) settled") {
                let agent = await core.agent(id)
                let released = await core.live[id] == nil
                return agent?.report != nil && agent?.state.holdsRuntime == false && released
            }
            // Blocked on a time an hour off: the app will check again by itself.
            var agent = try #require(await core.agent(id))
            agent.report = WorkReport(outcome: .blocked, message: "Waiting on the build", at: Date(),
                                      block: Block(checkAgainAt: Date().addingTimeInterval(3600)))
            await core.changed(agent)
        }

        // Behind the three waiting ones, which hold their places (#362).
        let queued = try await calling(core, token) { t in try await core.startHelper(.init(token: t, prompt: "Delta")) }
        #expect(queued.note.contains("3 of 3 agents started by agents running"))
        #expect(await core.agent(queued.agentID)?.state == .queued)

        try #require(!helpers.isEmpty)
        let parked = try await calling(core, token) { t in try await core.parkHelper(.init(token: t, agentID: helpers[0].uuidString)) }
        #expect(parked.hasSuffix("This project now has 2 of 3 running, 3 of 5 not archived, 1 of 5 queued."))
        await eventually("Delta started once a place freed") { await core.agent(queued.agentID)?.state != .queued }
    }

    @Test func thePersonsSettingTakesEffectAtTheNextStartAndIsKept() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let gate = TurnGate()
        defer { gate.open() }
        let core = try await makeCore(locations, heldTurns(gate))
        let (_, token) = try await caller(core, in: work)
        let limits = HelperLimits(running: 1, notArchived: 2, queued: 3)
        let summary = try await core.setHelperLimits(.init(folder: work, limits: limits))
        #expect(summary.project.helperLimits == limits)
        #expect(summary.helperLimits == (1, 2))

        let first = try await calling(core, token) { t in try await core.startHelper(.init(token: t, prompt: "Alpha")) }
        #expect(first.note.hasSuffix("This project now has 1 of 1 running, 1 of 2 not archived."))
        let second = try await calling(core, token) { t in try await core.startHelper(.init(token: t, prompt: "Beta")) }
        #expect(second.note.contains("1 of 1 agents started by agents running"))
        #expect(second.note.hasSuffix(", 1 of 3 queued."))

        // Read back by a daemon started again on the same root.
        let again = try await makeCore(locations, FakeLauncher())
        #expect(await again.projectSummary(for: work)?.project.helperLimits == limits)

        // Back to the defaults keeps no setting at all.
        let reset = try await core.setHelperLimits(.init(folder: work, limits: HelperLimits()))
        #expect(reset.project.helperLimits == nil)
        #expect(reset.helperLimits == (3, 5))
    }

    @Test func aSettingPastTheHardMaximumIsRefusedAndNothingChanges() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        _ = try await caller(core, in: work)

        for limits in [HelperLimits(running: 11), HelperLimits(notArchived: 21), HelperLimits(running: 0),
                       HelperLimits(running: 4, notArchived: 3), HelperLimits(queued: 0), HelperLimits(queued: 21)] {
            let error = await refusal { _ = try await core.setHelperLimits(.init(folder: work, limits: limits)) }
            #expect(error?.code == JSONRPCError.invalidParams, "\(limits)")
        }
        #expect(await core.projectSummary(for: work)?.project.helperLimits == nil)
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
        let callerTools = await eventuallySome("the lead listed its tools") {
            await launcher.lastAgent?.newSessionAppTools
        } ?? []
        #expect(callerTools.contains(AppTool.startAgent), "the person's agent has them")

        let helper = try await start(core, token)
        // Listed over http as its session is made, which is after `start_agent` answers.
        let madeTools = await eventuallySome("the helper listed its tools") { () async -> [String]? in
            guard let session = await core.agent(helper)?.runtimeSessionID else { return nil }
            for agent in launcher.allAgents where await agent.sessionID == session {
                return await agent.newSessionAppTools
            }
            return nil
        } ?? []
        #expect(madeTools.contains(AppTool.finishTurn))
        #expect(!madeTools.contains(AppTool.startAgent))

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
        let resumedTools = await eventuallySome("it was picked back up") { () async -> [String]? in
            for agent in launcher.allAgents.reversed() {
                guard let params = await agent.continuedSessionParams,
                      params["sessionId"]?.stringValue == sessionID else { continue }
                return await agent.continuedSessionAppTools
            }
            return nil
        } ?? []
        #expect(resumedTools.contains(AppTool.finishTurn), "\(resumedTools)")
        #expect(!resumedTools.contains(AppTool.startAgent), "\(resumedTools)")
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
        // Its own first turn over, so that ending does not let the run go.
        await settled(core, lead, "the lead's first turn ended")
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

    /// Turns held until the test opens the gate: for a test that needs them still going,
    /// which a fixed five seconds is not on a busy machine (#225).
    private func heldTurns(_ gate: TurnGate) -> FakeLauncher {
        var script = FakeACPAgent.Script()
        script.gate = gate
        return FakeLauncher(script: script)
    }

    @Test func stoppingOneItStartedSaysWhoStoppedIt() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let gate = TurnGate()
        defer { gate.open() }
        let core = try await makeCore(locations, heldTurns(gate))
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
        let helper = try await settledHelper(core, token, "Count the files")

        let note = try await calling(core, token) { t in try await core.stopHelper(.init(token: t, agentID: helper.uuidString)) }

        #expect(note.hasSuffix("had already stopped; nothing changed."))
        #expect(await core.agent(helper)?.state == .finished)
    }

    @Test func parkingOneItStartedPutsItUnderParked() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (_, token) = try await caller(core, in: work)
        let helper = try await settledHelper(core, token, "Count the files")

        let note = try await calling(core, token) { t in try await core.parkHelper(.init(token: t, agentID: helper.uuidString)) }

        let parked = try #require(await core.agent(helper))
        #expect(parked.parking?.isParked == true)
        #expect(parked.group(wantsEyes: false) == .parked)
        #expect(note.hasPrefix("Parked "))
        #expect(note.contains("freeing its running place; it keeps its other place until it is archived."))
        #expect(note.hasSuffix("This project now has 0 of 3 running, 1 of 5 not archived."))
    }

    @Test func parkingOneThatIsWorkingLetsTheTurnFinishThenParksIt() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let gate = TurnGate()
        defer { gate.open() }
        let core = try await makeCore(locations, heldTurns(gate))
        let (_, token) = try await caller(core, in: work)
        let helper = try await start(core, token)
        _ = await eventually("the helper is working") { await core.agent(helper)?.state == .running }

        let note = try await calling(core, token) { t in try await core.parkHelper(.init(token: t, agentID: helper.uuidString)) }

        #expect(note.hasSuffix("will park when its turn ends, freeing its running place then."))
        guard case .whenTurnEnds = await core.agent(helper)?.parking else {
            Issue.record("expected the helper to be marked")
            return
        }
        gate.open()
        _ = await eventually("the helper finished and parked") {
            await core.agent(helper)?.parking?.isParked == true
        }
        #expect(await core.agent(helper)?.group(wantsEyes: false) == .parked)
    }

    @Test func parkingTwiceChangesNothing() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (_, token) = try await caller(core, in: work)
        let helper = try await start(core, token)
        _ = await eventually("settled") { await core.agent(helper)?.state == .finished }
        _ = try await calling(core, token) { t in try await core.parkHelper(.init(token: t, agentID: helper.uuidString)) }

        let note = try await calling(core, token) { t in try await core.parkHelper(.init(token: t, agentID: helper.uuidString)) }

        #expect(note.hasSuffix("was already parked; nothing changed."))
        #expect(await core.agent(helper)?.parking?.isParked == true)
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
        let gate = TurnGate()
        defer { gate.open() }
        let core = try await makeCore(locations, heldTurns(gate))
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
            (persons.uuidString, "Nothing changed: that is one of the person's own sessions. "
                + "You can only stop, park or archive agents you started."),
            (workflows.uuidString, "Nothing changed: a workflow started that one. "
                + "You can only stop, park or archive agents you started."),
            (othersHelper.uuidString, "Nothing changed: another agent started that one. "
                + "You can only stop, park or archive agents you started."),
            ("not-an-id", "Nothing changed: there is no agent with that id."),
            (UUID().uuidString, "Nothing changed: there is no agent with that id."),
        ]
        for (target, expected) in cases {
            let stopped = await refusal { _ = try await calling(core, token) { t in try await core.stopHelper(.init(token: t, agentID: target)) } }
            #expect(stopped?.message == expected, "stop \(target)")
            // Its own id parks itself once its turn ends (#481), so it is no refusal.
            if target != lead.uuidString {
                let parked = await refusal { _ = try await calling(core, token) { t in try await core.parkHelper(.init(token: t, agentID: target)) } }
                #expect(parked?.message == expected, "park \(target)")
            }
            let archiveExpected = target == lead.uuidString ? DaemonCore.cannotArchiveItself : expected
            let archived = await refusal { _ = try await calling(core, token) { t in try await core.archiveHelper(.init(token: t, agentID: target)) } }
            #expect(archived?.message == archiveExpected, "archive \(target)")
        }

        let after = await core.allAgents().map { "\($0.id) \($0.state) \(String(describing: $0.endedReason))" }.sorted()
        #expect(before == after)
    }

    // MARK: Archiving (#120)

    /// A helper of its own, finished, its ending accounted for, and let go.
    private func settledHelper(_ core: DaemonCore, _ token: String, _ name: String) async throws -> UUID {
        let id = try await start(core, token, name)
        _ = await eventually("\(name) settled") {
            guard let agent = await core.agent(id) else { return false }
            let turning = await core.turnTasks[id] != nil
            let sending = await core.sending.contains(id)
            let released = await core.live[id] == nil
            return agent.report != nil && !agent.state.holdsRuntime && agent.queuedPrompts.isEmpty
                && !turning && !sending && released
        }
        return id
    }

    @Test func archivingOneItStartedFreesItsPlaceSaysWhoAndThePersonCanBringItBack() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (_, token) = try await caller(core, in: work, title: "Lead")
        let alpha = try await settledHelper(core, token, "Alpha")
        _ = try await start(core, token, "Beta")

        let note = try await calling(core, token) { t in try await core.archiveHelper(.init(token: t, agentID: alpha.uuidString)) }

        let archived = try #require(await core.agent(alpha))
        #expect(archived.state == .archived)
        #expect(archived.archivedReason == .byAgent)
        #expect(note.hasPrefix("Archived \u{201C}Alpha\u{201D}, freeing its place; the person can bring it back."))
        #expect(note.hasSuffix(" 1 of 5 not archived."))
        #expect(try await notes(core, alpha).contains("\u{201C}Lead\u{201D} archived this agent."))
        // The only archive here, so the only `agent.archived`: by another agent.
        let raised = await eventually("agent.archived raised") {
            await core.eventLog.events.contains { $0.name == "agent.archived" }
        }
        #expect(raised)
        #expect(await core.eventLog.events.filter { $0.name == "agent.archived" }.map { $0.details["by"] } == ["agent"])
        let list = try await calling(core, token) { t in try await core.listHelpers(.init(token: t)) }
        #expect(!list.contains(alpha.uuidString))

        try await core.unarchive(alpha)   // by the person
        #expect(await core.agent(alpha)?.state != .archived)
    }

    @Test func anAgentCannotArchiveItself() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (lead, token) = try await caller(core, in: work)
        let helper = try await settledHelper(core, token, "Alpha")
        let helperToken = UUID().uuidString
        callers[helperToken] = helper

        let leadError = await refusal { _ = try await calling(core, token) { t in try await core.archiveHelper(.init(token: t, agentID: lead.uuidString)) } }
        #expect(leadError?.message == "Nothing changed: you can't archive yourself. Call park_agent with no id "
                + "to be parked when your turn ends; the person or the agent that started you can archive you.")
        // A helper hears the same, rather than that it may not use the tools at all.
        let helperError = await refusal { _ = try await calling(core, helperToken) { t in try await core.archiveHelper(.init(token: t, agentID: helper.uuidString)) } }
        #expect(helperError?.message == DaemonCore.cannotArchiveItself)
        #expect(await core.agent(lead)?.state != .archived)
        #expect(await core.agent(helper)?.state != .archived)
    }

    @Test func aHelperStillWorkingIsNotArchived() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let gate = TurnGate()
        defer { gate.open() }
        let core = try await makeCore(locations, heldTurns(gate))
        let (_, token) = try await caller(core, in: work)
        let helper = try await start(core, token, "Alpha")
        _ = await eventually("the helper is working") { await core.agent(helper)?.state == .running }

        let error = await refusal { _ = try await calling(core, token) { t in try await core.archiveHelper(.init(token: t, agentID: helper.uuidString)) } }

        #expect(error?.message == "Nothing changed: \u{201C}Alpha\u{201D} is still working. Wait for it to finish, "
                + "or stop it with stop_agent if its work is no longer wanted, then archive it.")
        #expect(await core.agent(helper)?.state == .running)
    }

    @Test func withTheSwitchOffOnlyThePersonArchives() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (_, token) = try await caller(core, in: work)
        let helper = try await settledHelper(core, token, "Alpha")
        let summary = try await core.setHelperLimits(.init(folder: work, limits: HelperLimits(agentsMayArchive: false)))
        #expect(summary.project.helperLimits?.mayArchive == false)

        let error = await refusal { _ = try await calling(core, token) { t in try await core.archiveHelper(.init(token: t, agentID: helper.uuidString)) } }

        #expect(error?.message == "Nothing changed: in this project only the person archives; they can let agents "
                + "archive the helpers they started in Project Settings. Park \u{201C}Alpha\u{201D} with park_agent instead.")
        #expect(await core.agent(helper)?.state != .archived)
        // Back on, which is the default and so keeps no record.
        let reset = try await core.setHelperLimits(.init(folder: work, limits: HelperLimits(agentsMayArchive: true)))
        #expect(reset.project.helperLimits == nil)
        _ = try await calling(core, token) { t in try await core.archiveHelper(.init(token: t, agentID: helper.uuidString)) }
        #expect(await core.agent(helper)?.state == .archived)
    }

    // MARK: Listing (US4)

    @Test func listingShowsOnlyItsOwnWithStateAndTheCount() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (_, token) = try await caller(core, in: work)
        let (_, otherToken) = try await caller(core, in: work, title: "Other")
        let mine = try await settledHelper(core, token, "Alpha")
        let theirs = try await start(core, otherToken, "Beta")

        let list = try await calling(core, token) { t in try await core.listHelpers(.init(token: t)) }

        let lines = list.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("This project has ") == true)
        #expect(lines.first?.hasSuffix(" running, 2 of 5 not archived.") == true)
        #expect(list.contains("- \(mine.uuidString): \u{201C}Alpha\u{201D} — finished"))
        #expect(!list.contains(theirs.uuidString))
    }

    @Test func listingWithNoneSaysSo() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let core = try await makeCore(locations, FakeLauncher())
        let (_, token) = try await caller(core, in: work)

        let list = try await calling(core, token) { t in try await core.listHelpers(.init(token: t)) }
        #expect(list.hasPrefix("You have not started any agents that are still here. "
                               + "This project has 0 of 3 running, 0 of 5 not archived.\n"))
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
