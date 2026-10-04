import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// `list_sessions` and `read_session` on a daemon (065, US1 and US3): every agent in a
/// project can find and read another session there, and the session read is untouched.
@Suite("Reading another session", .timeLimit(.minutes(1)))
struct SessionToolsTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsSessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StoreLocations(root: root), root.resolvingSymlinksInPath())
    }

    private func project(_ root: URL, _ name: String = "api") throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Project.standardize(url)
    }

    private func makeCore(_ locations: StoreLocations) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        return core
    }

    /// A session with a title, its first turn over, and who it is. A session's token is
    /// dropped when its runtime is let go, so each call binds a fresh one first, as
    /// `HelperAgentTests` does.
    private func session(_ core: DaemonCore, in folder: URL, title: String?,
                         prompt: String = "Fix the login redirect") async throws -> UUID {
        let id = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: folder, prompt: prompt))
        await settle(core, id)
        await core.nameForTesting(id, title)
        return id
    }

    /// Quiet: no turn in flight, nothing queued, the runtime let go, and the record not
    /// growing. After a turn that did not say how it went, the app asks, in a second
    /// turn of its own; a read taken during that would see the source change under it.
    private func settle(_ core: DaemonCore, _ id: UUID) async {
        var last = -1
        var steady = 0
        let deadline = ContinuousClock.now.advanced(by: Eventually.timeout)
        while ContinuousClock.now < deadline {
            let agent = await core.agent(id)
            let live = await core.live[id]
            let total = (try? await core.transcript(.init(agentID: id, before: nil, limit: 1)).total) ?? -1
            let quiet = agent.map { !$0.state.hasTurnInFlight && $0.queuedPrompts.isEmpty } == true && live == nil
            steady = quiet && total == last ? steady + 1 : 0
            last = total
            if steady >= 5 { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("the session never settled")
    }

    private func token(_ core: DaemonCore, _ id: UUID) async -> String {
        let token = UUID().uuidString
        await core.bindAppToken(token, to: id)
        return token
    }

    private func list(_ core: DaemonCore, _ caller: UUID) async throws -> String {
        try await core.listSessions(.init(token: await token(core, caller)))
    }

    private func read(_ core: DaemonCore, _ caller: UUID, _ value: String) async throws -> String {
        try await core.readSession(.init(token: await token(core, caller), session: value))
    }

    // MARK: Listing

    @Test func theListIsEverySessionInTheProjectAndNoneElsewhere() async throws {
        let (locations, root) = try temporary()
        let api = try project(root)
        let web = try project(root, "web")
        let core = try await makeCore(locations)
        let source = try await session(core, in: api, title: "Login redirect")
        let caller = try await session(core, in: api, title: nil, prompt: "Carry on")
        let elsewhere = try await session(core, in: web, title: "Theirs")

        let text = try await list(core, caller)
        #expect(text.contains("\(source.uuidString): \u{201C}Login redirect\u{201D} — Claude"))
        #expect(text.contains("\(caller.uuidString): Untitled (you)"))
        #expect(!text.contains(elsewhere.uuidString))
        #expect(!text.contains("Theirs"))
    }

    /// The clean-up workflow (#199) leaves alone a worktree whose session holds a lease.
    @Test func aSessionHoldingALeaseSaysSo() async throws {
        let (locations, root) = try temporary()
        let api = try project(root)
        let core = try await makeCore(locations)
        let holder = try await session(core, in: api, title: "Building")
        let caller = try await session(core, in: api, title: nil, prompt: "Clean up")
        _ = try await core.lease(.init(token: await token(core, holder), name: "build", minutes: 5, wait: false))

        let lines = try await list(core, caller).split(separator: "\n")
        let held = lines.first { $0.contains(holder.uuidString) } ?? ""
        #expect(held.contains("Holding: build."))
        #expect(!(lines.first { $0.contains(caller.uuidString) } ?? "").contains("Holding:"))
    }

    // MARK: Reading

    @Test func aSessionIsReadByTitleAndLeftAsItWas() async throws {
        let (locations, root) = try temporary()
        let api = try project(root)
        let core = try await makeCore(locations)
        let source = try await session(core, in: api, title: "Login redirect")
        await core.record(.toolCall(ToolCall(title: "Edit router.swift",
                                             locations: [ToolCallLocation(path: api.path + "/router.swift")])),
                          for: source)
        await core.record(.planUpdated(Plan(entries: [PlanEntry(content: "Add a test")])), for: source)
        let caller = try await session(core, in: api, title: nil, prompt: "Carry on")
        await settle(core, source)

        let before = try #require(await core.agent(source))
        let countBefore = try await core.transcript(.init(agentID: source, before: nil, limit: 1)).total

        let text = try await read(core, caller, "Login redirect")
        #expect(text.hasPrefix("# Session \u{201C}Login redirect\u{201D}"))
        #expect(text.contains("**The person:** Fix the login redirect"))
        #expect(text.contains("Edit router.swift (`\(api.path)/router.swift`)"))
        #expect(text.contains("- [ ] Add a test"))

        let after = try #require(await core.agent(source))
        #expect(after == before)
        let countAfter = try await core.transcript(.init(agentID: source, before: nil, limit: 1)).total
        #expect(countAfter == countBefore)
    }

    @Test func aSessionIsReadByIdAndTheCallerCanReadItself() async throws {
        let (locations, root) = try temporary()
        let api = try project(root)
        let core = try await makeCore(locations)
        let source = try await session(core, in: api, title: "Login redirect")
        let caller = try await session(core, in: api, title: "Me", prompt: "Carry on")

        #expect(try await read(core, caller, source.uuidString).contains(source.uuidString))
        #expect(try await read(core, caller, caller.uuidString).contains("**The person:** Carry on"))
    }

    @Test func anArchivedSessionIsReadable() async throws {
        let (locations, root) = try temporary()
        let api = try project(root)
        let core = try await makeCore(locations)
        let source = try await session(core, in: api, title: "Old work")
        try await core.archive(source)
        let caller = try await session(core, in: api, title: nil, prompt: "Carry on")

        #expect(try await read(core, caller, "Old work").contains("Fix the login redirect"))
    }

    // MARK: Refusals, in the words the agent reads

    @Test func missingDuplicateAndEmptyAreRefusedInWords() async throws {
        let (locations, root) = try temporary()
        let api = try project(root)
        let core = try await makeCore(locations)
        _ = try await session(core, in: api, title: "Twice")
        _ = try await session(core, in: api, title: "Twice", prompt: "Again")
        let caller = try await session(core, in: api, title: nil, prompt: "Carry on")

        #expect(try await read(core, caller, "Nope") == SessionLookup.missing("Nope"))
        #expect(try await read(core, caller, "Twice").hasPrefix("More than one session is named \u{201C}Twice\u{201D}"))
        #expect(try await read(core, caller, " ") == SessionLookup.noValue)
    }

    @Test func aRetiredSessionIsGone() async throws {
        let (locations, root) = try temporary()
        let api = try project(root)
        let core = try await makeCore(locations)
        let source = try await session(core, in: api, title: "Retired work")
        try await core.archive(source)
        try await core.retire(source, because: .person)
        let caller = try await session(core, in: api, title: nil, prompt: "Carry on")

        #expect(try await read(core, caller, "Retired work") == SessionLookup.gone)
        #expect(try await read(core, caller, source.uuidString) == SessionLookup.gone)
    }

    @Test func anotherProjectsSessionIsNotThere() async throws {
        let (locations, root) = try temporary()
        let core = try await makeCore(locations)
        let theirs = try await session(core, in: try project(root, "web"), title: "Theirs")
        let caller = try await session(core, in: try project(root), title: nil, prompt: "Carry on")

        #expect(try await read(core, caller, theirs.uuidString) == SessionLookup.missing(theirs.uuidString))
        #expect(try await read(core, caller, "Theirs") == SessionLookup.missing("Theirs"))
    }

    // MARK: Who may

    @Test func anAgentAnotherAgentStartedCanListAndRead() async throws {
        let (locations, root) = try temporary()
        let api = try project(root)
        let core = try await makeCore(locations)
        _ = try await session(core, in: api, title: "Login redirect")
        let lead = try await session(core, in: api, title: "Lead", prompt: "Lead")
        let helper = try await core.startHelper(.init(token: await token(core, lead), prompt: "Help")).agentID

        #expect(try await list(core, helper).contains("Login redirect"))
        #expect(try await read(core, helper, "Login redirect").contains("Fix the login redirect"))
    }

    @Test func aTokenThatSpeaksForNobodyIsRefused() async throws {
        let (locations, _) = try temporary()
        let core = try await makeCore(locations)
        await #expect(throws: JSONRPCError.self) { try await core.listSessions(.init(token: "nobody")) }
        await #expect(throws: JSONRPCError.self) { try await core.readSession(.init(token: "nobody", session: "x")) }
    }

    @Test func bothToolsAreTheAppsSoNobodyIsAskedFirst() {
        #expect(AppTool.all.contains(AppTool.listSessions))
        #expect(AppTool.all.contains(AppTool.readSession))
        #expect(AppTool.isServedByTheApp("mcp__agents__read_session"))
        #expect(ConnectionRole.agentMethods.contains(DaemonAPI.Method.agentsListSessions))
        #expect(ConnectionRole.agentMethods.contains(DaemonAPI.Method.agentsReadSession))
    }

    @Test func aReadWithoutASessionIsRefusedBeforeItReachesTheDaemon() {
        guard case .failure(let problem)? = AppService.sessionCall(named: "mcp__agents__read_session", ["session": " "]) else {
            Issue.record("an empty read was not refused"); return
        }
        #expect(problem.message == SessionLookup.noValue)
        guard case .success(.read(let value))? = AppService.sessionCall(named: "agents_read_session",
                                                                         ["session": " Login redirect "]) else {
            Issue.record("a read was not read"); return
        }
        #expect(value == "Login redirect")
        #expect(AppService.sessionCall(named: "mcp__agents__list_sessions", nil).map { (try? $0.get()) == .list() } == true)
    }

    @Test func bothToolsAreOfferedToEveryAgentIncludingAHelper() {
        for managesAgents in [true, false] {
            let names = AppService.tools(managesAgents: managesAgents).compactMap { $0["name"]?.stringValue }
            #expect(names.contains(AppTool.listSessions))
            #expect(names.contains(AppTool.readSession))
        }
    }
}

extension DaemonCore {
    /// A title as the person or the agent would have given it, without a turn to give it in.
    func nameForTesting(_ id: UUID, _ title: String?) {
        agents[id]?.title = title
    }
}
