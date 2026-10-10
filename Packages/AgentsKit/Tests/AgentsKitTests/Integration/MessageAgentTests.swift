import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// `message_agent` on a daemon (#560): any agent in a project tells any session there
/// something, which reads as a prompt marked as the sender's, within the limits that keep
/// that from running away.
@Suite("Messaging another agent", .timeLimit(.minutes(1)))
struct MessageAgentTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsMessages-\(UUID().uuidString)", isDirectory: true)
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

    /// A session the person started, its first turn over.
    private func session(_ core: DaemonCore, in folder: URL, title: String,
                         prompt: String = "Fix the login redirect") async throws -> UUID {
        let id = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: folder, prompt: prompt))
        await settle(core, id)
        await core.nameForTesting(id, title)
        return id
    }

    /// One another agent started, its first turn over.
    private func helper(_ core: DaemonCore, of lead: UUID, title: String) async throws -> UUID {
        let id = try await core.startHelper(.init(token: await token(core, lead), prompt: "Help")).agentID
        await settle(core, id)
        await core.nameForTesting(id, title)
        return id
    }

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

    private func send(_ core: DaemonCore, from caller: UUID, to target: String, _ text: String) async throws -> String {
        try await core.messageAgent(.init(token: await token(core, caller), to: target, message: text))
    }

    private func refusal(_ core: DaemonCore, from caller: UUID, to target: String,
                         _ text: String = "Hello") async -> String? {
        do {
            _ = try await send(core, from: caller, to: target, text)
            return nil
        } catch let error as JSONRPCError {
            return error.message
        } catch {
            return "\(error)"
        }
    }

    private func entries(_ core: DaemonCore, _ id: UUID) async throws -> [TranscriptEntry] {
        try await core.transcript(.init(agentID: id, before: nil, limit: 500)).entries
    }

    // MARK: Delivery

    @Test func aMessageWakesAFinishedHelperAndIsDrawnAsTheSenders() async throws {
        let (locations, root) = try temporary()
        let api = try project(root)
        let core = try await makeCore(locations)
        let lead = try await session(core, in: api, title: "Lead", prompt: "Lead")
        let reviewer = try await helper(core, of: lead, title: "Reviewer")

        let note = try await send(core, from: lead, to: "Reviewer", "Please label yourself 'reviewed'.")
        #expect(note.contains("working on it now"))
        await settle(core, reviewer)

        let message = try await entries(core, reviewer).last { entry in
            if case .userMessage(_, _, .agent) = entry.kind { return true }
            return false
        }
        let sent = try #require(message)
        guard case .userMessage(let text, _, _) = sent.kind else { return }
        // The words alone: who sent them is the entry's, and the preface never drawn.
        #expect(text == "Please label yourself 'reviewed'.")
        #expect(sent.sender == MessageSender(agentID: lead, title: "Lead"))
    }

    @Test func aSessionThePersonStartedIsQueuedNotWoken() async throws {
        let (locations, root) = try temporary()
        let api = try project(root)
        let core = try await makeCore(locations)
        let mine = try await session(core, in: api, title: "Mine")
        let lead = try await session(core, in: api, title: "Lead", prompt: "Lead")
        let other = try await helper(core, of: lead, title: "Other")
        let before = try await entries(core, mine).count

        let note = try await send(core, from: other, to: mine.uuidString, "Done with the API half.")
        #expect(note.contains("which the person started"))
        let agent = try #require(await core.agent(mine))
        #expect(agent.queuedPrompts.count == 1)
        #expect(agent.queuedPrompts.first?.from == .agent)
        #expect(agent.queuedPrompts.first?.sender?.title == "Other")
        #expect(!agent.state.hasTurnInFlight)
        #expect(try await entries(core, mine).count == before)
    }

    @Test func aMessageRaisesAnEventNamingTheSender() async throws {
        let (locations, root) = try temporary()
        let api = try project(root)
        let core = try await makeCore(locations)
        let mine = try await session(core, in: api, title: "Mine")
        let lead = try await session(core, in: api, title: "Lead", prompt: "Lead")

        _ = try await send(core, from: lead, to: "Mine", "Hello")
        let events = await core.eventLog.events
        let messaged = try #require(events.last { $0.name == "agent.messaged" })
        #expect(messaged.details["agent"] == mine.uuidString)
        #expect(messaged.details["from"] == lead.uuidString)
        #expect(messaged.details["from_title"] == "Lead")
    }

    // MARK: Limits

    @Test func theLoopGuardStopsTheFourthMessageInARow() async throws {
        let (locations, root) = try temporary()
        let api = try project(root)
        let core = try await makeCore(locations)
        let a = try await session(core, in: api, title: "A")
        _ = try await session(core, in: api, title: "B")

        await core.setMessageHopsForTesting(a, AgentMessageLimits.hops - 1)
        let last = try await send(core, from: a, to: "B", "Third")
        #expect(last.contains("the last message in a row"))
        #expect(await core.agent(a)?.queuedPrompts.isEmpty == true)

        await core.setMessageHopsForTesting(a, AgentMessageLimits.hops)
        let refused = try #require(await refusal(core, from: a, to: "B"))
        #expect(refused.hasPrefix("Nothing was sent:"))
        #expect(refused.contains("Ask the person"))
    }

    @Test func thePersonsPromptStartsTheCountAgain() async throws {
        let (locations, root) = try temporary()
        let api = try project(root)
        let core = try await makeCore(locations)
        let a = try await session(core, in: api, title: "A")
        _ = try await session(core, in: api, title: "B")
        await core.setMessageHopsForTesting(a, AgentMessageLimits.hops)

        try await core.prompt(.init(agentID: a, text: "Carry on"))
        await settle(core, a)
        #expect(await core.messageHops[a] == nil)
        #expect(await refusal(core, from: a, to: "B") == nil)
    }

    @Test func aSenderIsHeldToItsHourlyCount() async throws {
        let (locations, root) = try temporary()
        let api = try project(root)
        let core = try await makeCore(locations)
        let a = try await session(core, in: api, title: "A")
        _ = try await session(core, in: api, title: "B")
        await core.setMessagesSentForTesting(a, Array(repeating: Date(), count: AgentMessageLimits.perHour))

        let refused = try #require(await refusal(core, from: a, to: "B"))
        #expect(refused.contains("in the last hour"))
    }

    @Test func tooLongToItselfOrArchivedIsRefused() async throws {
        let (locations, root) = try temporary()
        let api = try project(root)
        let web = try project(root, "web")
        let core = try await makeCore(locations)
        let a = try await session(core, in: api, title: "A")
        let gone = try await session(core, in: api, title: "Gone")
        _ = try await session(core, in: web, title: "Elsewhere")
        try await core.archive(gone)

        let long = String(repeating: "x", count: AgentMessageLimits.characters + 1)
        #expect(try #require(await refusal(core, from: a, to: "Gone")).contains("archived"))
        #expect(try #require(await refusal(core, from: a, to: "A")).contains("that is this session"))
        #expect(try #require(await refusal(core, from: a, to: "Elsewhere")).contains("There is no session named"))
        #expect(try #require(await refusal(core, from: a, to: gone.uuidString, long)).contains("at most"))
    }

    // MARK: The tool

    @Test func theToolIsTheAppsAndOfferedToEveryAgent() {
        #expect(AppTool.all.contains(AppTool.messageAgent))
        #expect(AppTool.isServedByTheApp("mcp__agents__message_agent"))
        #expect(ConnectionRole.agentMethods.contains(DaemonAPI.Method.agentsMessageAgent))
        for managesAgents in [true, false] {
            let names = AppService.tools(managesAgents: managesAgents).compactMap { $0["name"]?.stringValue }
            #expect(names.contains(AppTool.messageAgent))
        }
    }

    @Test func aMessageWithoutWordsOrATargetIsRefusedBeforeItReachesTheDaemon() {
        guard case .failure? = AppService.sessionCall(named: "mcp__agents__message_agent", ["to": " ", "message": "Hi"]),
              case .failure? = AppService.sessionCall(named: "mcp__agents__message_agent", ["to": "A", "message": " "])
        else {
            Issue.record("an empty message was not refused"); return
        }
        guard case .success(.message(let to, let text))? = AppService.sessionCall(
            named: "agents_message_agent", ["to": " Reviewer ", "message": " Label yourself. "]) else {
            Issue.record("a message was not read"); return
        }
        #expect(to == "Reviewer")
        #expect(text == "Label yourself.")
    }
}

extension DaemonCore {
    func setMessageHopsForTesting(_ id: UUID, _ hops: Int) {
        messageHops[id] = hops
    }

    func setMessagesSentForTesting(_ id: UUID, _ times: [Date]) {
        messagesSent[id] = times
    }
}
