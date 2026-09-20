import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// An agent saying what you might want to ask next.
///
/// ACP has no way to send one, so the app serves an MCP server with a single tool on
/// it and attaches that server to every session. These are the tests for the daemon's
/// half of that: that the server is attached at all, that only the session it was
/// minted for can post through it, and that a suggestion stops being shown the moment
/// the turn it belonged to is over.
@Suite("Suggesting what to ask next", .timeLimit(.minutes(1)))
struct SuggestedPromptTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsSuggestTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func core(_ launcher: FakeLauncher, locations: StoreLocations) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations),
                   locations: locations,
                   discovery: .findsEverything,
                   launcher: launcher)
    }

    private func servers(in params: JSONValue?) -> [JSONValue] {
        params?["mcpServers"]?.arrayValue ?? []
    }

    /// Wait until the turn is over, nothing is queued, and the runtime has been let go.
    ///
    /// All three, because the agent reads as finished a moment before its runtime is
    /// released, and a prompt sent in that moment goes to the session that is still
    /// there rather than picking a new one up. A fixed sleep hits that window now and
    /// then, which is the worst kind of test: it passes alone and fails in a full run.
    private func settle(_ core: DaemonCore, _ id: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let agent = await core.agent(id),
               !agent.state.hasTurnInFlight, agent.queuedPrompts.isEmpty,
               await core.live[id] == nil {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Attaching the server

    @Test func everySessionIsGivenTheSuggestionServer() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        let attached = servers(in: await launcher.lastAgent?.newSessionParams)
        #expect(attached.count == 1)
        #expect(attached.first?["name"]?.stringValue == "agents")
        // Stdio, because it is the only transport every runtime takes: the acp
        // transport is unstable and none of the three advertise it.
        #expect(attached.first?["command"]?.stringValue != nil)
        #expect(attached.first?["args"]?.arrayValue?.first?.stringValue == "mcp")
    }

    /// The gap this found: servers the user attached were recorded against the agent
    /// and never sent, because `session/new` was called without them.
    @Test func theServersTheUserAttachedGoWithIt() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)
        let theirs = MCPServer(name: "theirs", transport: .http(url: "https://example.com", headers: [:]))

        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go",
                                       mcpServers: [theirs]))

        let names = servers(in: await launcher.lastAgent?.newSessionParams)
            .compactMap { $0["name"]?.stringValue }
        #expect(names == ["theirs", "agents"])
    }

    /// A draft session was made before the user chose a server, so it cannot be the
    /// session that server is attached to.
    @Test func aDraftMadeWithoutAServerIsNotReusedForOneThatHasIt() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)
        let theirs = MCPServer(name: "theirs", transport: .http(url: "https://example.com", headers: [:]))

        let draft = try await core.options(.init(runtimeID: "copilot", cwd: work))
        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go",
                                       draftID: draft.draftID, mcpServers: [theirs]))

        #expect(launcher.launchCount == 2)
        let names = servers(in: await launcher.lastAgent?.newSessionParams)
            .compactMap { $0["name"]?.stringValue }
        #expect(names == ["theirs", "agents"])
    }

    @Test func aDraftMadeWithTheSameServersIsUsedAsItIs() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)
        let theirs = MCPServer(name: "theirs", transport: .http(url: "https://example.com", headers: [:]))

        let draft = try await core.options(.init(runtimeID: "copilot", cwd: work, mcpServers: [theirs]))
        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go",
                                       draftID: draft.draftID, mcpServers: [theirs]))

        #expect(launcher.launchCount == 1)
    }

    // MARK: What a call does

    /// The token the runtime was given is minted before the agent exists, and means
    /// something only once the start has made one.
    private func token(_ core: DaemonCore, _ launcher: FakeLauncher) async -> String {
        let attached = servers(in: await launcher.lastAgent?.newSessionParams)
        return attached.first?["args"]?.arrayValue?.last?.stringValue ?? ""
    }

    /// Wait until the runtime has actually been handed its token.
    ///
    /// The token is minted before the agent exists and reaches the runtime in
    /// `session/new`, so there is a moment after `start` returns in which `token` is
    /// still the empty string. Calling the tool with that gets a refusal, which is
    /// what the fixed sleeps here used to hit under load.
    private func mintedToken(_ core: DaemonCore, _ launcher: FakeLauncher) async -> String {
        await eventuallySome("the runtime was handed its token") {
            let minted = await token(core, launcher)
            return minted.isEmpty ? nil : minted
        } ?? ""
    }

    /// A turn long enough to call a tool in the middle of, which is when a real one is
    /// called: the daemon lets the runtime go the moment a turn ends, and with it the
    /// MCP helper that runtime started.
    private func midTurn() -> FakeLauncher {
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(400)
        return FakeLauncher(script: script)
    }

    private func suggest(_ core: DaemonCore, _ launcher: FakeLauncher, _ labels: String...) async throws {
        _ = try await core.suggestPrompts(.init(token: await mintedToken(core, launcher),
                                                prompts: labels.map {
            SuggestedPrompt(label: $0, prompt: "Please: \($0)")
        }))
    }

    @Test func whatTheAgentPassesTheToolEndsUpOnTheAgent() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        let note = try await core.suggestPrompts(.init(token: await mintedToken(core, launcher), prompts: [
            SuggestedPrompt(label: "Run the tests", prompt: "Run the tests and fix what fails"),
            SuggestedPrompt(label: "Commit it", prompt: "Commit this with a message saying why"),
        ]))

        #expect(await core.agent(id)?.suggestedPrompts.map(\.label) == ["Run the tests", "Commit it"])
        // The agent is told what became of them, because it asked.
        #expect(note.contains("2"))
    }

    @Test func aTokenTheDaemonDoesNotKnowIsRefused() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)
        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        await #expect(throws: JSONRPCError.self) {
            _ = try await core.suggestPrompts(.init(token: "not-a-token", prompts: [
                SuggestedPrompt(label: "Anything", prompt: "Do anything"),
            ]))
        }
    }

    /// Anything on this Mac can reach the daemon's socket, so a token that has been
    /// retired must not still speak for the agent it once did.
    @Test func aTokenStopsWorkingWhenItsRuntimeIsGone() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        let stale = await mintedToken(core, launcher)

        // It works while the runtime is there, and not after.
        _ = try await core.suggestPrompts(.init(token: stale, prompts: [
            SuggestedPrompt(label: "While alive", prompt: "Do it"),
        ]))
        try await core.stop(id)
        await eventually("the runtime was let go") { await core.live[id] == nil }

        await #expect(throws: JSONRPCError.self) {
            _ = try await core.suggestPrompts(.init(token: stale, prompts: [
                SuggestedPrompt(label: "Anything", prompt: "Do anything"),
            ]))
        }
    }

    @Test func fourIsTheMostThatAreKept() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        _ = try await core.suggestPrompts(.init(token: await mintedToken(core, launcher),
                                                prompts: (1...9).map {
            SuggestedPrompt(label: "\($0)", prompt: "Do \($0)")
        }))

        #expect(await core.agent(id)?.suggestedPrompts.count == SuggestedPrompt.limit)
    }

    // MARK: Asking for them

    /// The finding that made this necessary: offered the tool and nothing else, all
    /// three runtimes called it never. One line in the prompt is what changes that.
    @Test func theRuntimeIsAskedForThemWhenTheConversationStarts() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "do the thing"))
        await eventually("the prompt reached the runtime") {
            await launcher.allAgents.first?.promptContent != nil
        }

        // The first runtime's, not the last one's: a turn that ends without saying how
        // it went is asked, and that question starts a runtime of its own.
        let sent = await launcher.allAgents.first?.promptContent?.arrayValue ?? []
        #expect(sent.count == 2)
        #expect(sent.first?["text"]?.stringValue == "do the thing")
        #expect(sent.last?["text"]?.stringValue == Briefing.text)
    }

    /// Asked once. The runtime keeps it in its own history and replays that history
    /// when the conversation is picked back up, so sending it again every turn would
    /// be tokens spent on something the runtime already has.
    @Test func andNotAgainOnEveryPromptAfterThat() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "do the thing"))
        try await settle(core, id)
        try await core.prompt(.init(agentID: id, text: "and the next thing"))
        try await settle(core, id)

        let sent = await prompts(launcher)
        #expect(sent == [["do the thing", Briefing.text],
                         ["and the next thing"]])
    }

    /// Every prompt of the person's that reached a runtime, in order, as lists of the
    /// text in it.
    ///
    /// Asked of every runtime the launcher made rather than of the last one: the
    /// daemon starts the next runtime before it has anything to send it, so "the last
    /// one" is sometimes a process that has not been spoken to yet.
    ///
    /// The app's own question after a silent ending is left out. It is a prompt and it
    /// does reach a runtime, but these tests are about what the briefing rides on, and
    /// 014's question is covered where it belongs, in `UnreportedEndingTests`.
    private func prompts(_ launcher: FakeLauncher) async -> [[String]] {
        var sent: [[String]] = []
        for fake in launcher.allAgents {
            guard let blocks = await fake.promptContent?.arrayValue else { continue }
            let texts = blocks.compactMap { $0["text"]?.stringValue }
            if texts.contains(where: { $0.contains(AppTool.reportOutcome) && $0.hasPrefix("That turn") }) {
                continue
            }
            sent.append(texts)
        }
        return sent
    }

    /// Except here. A runtime that has lost the conversation is starting a new one,
    /// and the ask went with the history it no longer has.
    @Test func aRuntimeThatLostTheConversationIsAskedAgain() async throws {
        let (locations, work) = try temporary()
        var gone = FakeACPAgent.Script()
        gone.supportsResume = true
        gone.sessionGoneError = JSONRPCError(code: -32000, message: "no such session")
        // The first runtime starts the agent and the second has forgotten it. The
        // launcher hands out `then` before it falls back to the default, so the
        // ordinary one goes there and the forgetful one is what is left.
        let launcher = FakeLauncher(script: gone, then: [.init()])
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "do the thing"))
        try await settle(core, id)
        try await core.prompt(.init(agentID: id, text: "carry on"))
        try await settle(core, id)

        // Two prompts, and the ask on both: the second runtime is a conversation
        // starting again, however much of it the app still has on its own record.
        let sent = await prompts(launcher)
        #expect(sent == [["do the thing", Briefing.text],
                         ["carry on", Briefing.text]])
    }

    /// Ours is a block of its own and not part of what was said. The transcript is a
    /// record of the conversation, and putting our words in the user's mouth would
    /// make it a record of something that did not happen.
    @Test func whatWeAddIsNotWhatTheRecordSays() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "do the thing"))
        await eventually("the prompt is on the record") {
            let page = try? await core.transcript(.init(agentID: id))
            return page?.entries.contains { if case .userMessage = $0.kind { return true } else { return false } } == true
        }

        let said = try await core.transcript(.init(agentID: id)).entries.compactMap { entry -> String? in
            if case .userMessage(let text, _, _) = entry.kind { return text }
            return nil
        }
        #expect(said == ["do the thing"])
    }

    // MARK: When they stop being shown

    @Test func theyGoWhenTheNextPromptGoes() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        try await suggest(core, launcher, "Run the tests")
        #expect(await core.agent(id)?.suggestedPrompts.isEmpty == false)
        // Still there once the turn has ended: this is what the chips are for.
        try await settle(core, id)
        #expect(await core.agent(id)?.suggestedPrompts.isEmpty == false)

        try await core.prompt(.init(agentID: id, text: "something else entirely"))
        await eventually("the suggestions went with the new prompt") {
            await core.agent(id)?.suggestedPrompts.isEmpty == true
        }
        #expect(await core.agent(id)?.suggestedPrompts.isEmpty == true)
    }

    /// They outlive the daemon, because the turn they came from does.
    @Test func theyAreStillThereWhenTheRecordIsOpenedAgain() async throws {
        let (locations, work) = try temporary()
        let launcher = midTurn()
        let core = try core(launcher, locations: locations)
        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        try await suggest(core, launcher, "Run the tests")
        // The file, not the daemon's memory: every save after the first goes on a
        // detached task, so the record in hand is right well before the record on disk
        // is, and the record on disk is what the core below opens.
        await eventually("the suggestions reached the file") {
            let onDisk = try? await AgentStore(locations: locations).load(id).agent
            return onDisk?.suggestedPrompts.map(\.label) == ["Run the tests"]
        }

        let reopened = DaemonCore(store: try AgentStore(locations: locations),
                                  locations: locations,
                                  discovery: .findsEverything,
                                  launcher: FakeLauncher())
        await reopened.loadFromDisk()
        #expect(await reopened.agent(id)?.suggestedPrompts.map(\.label) == ["Run the tests"])
    }

    // MARK: What it looks like in the app

    /// Copilot asks permission before every tool call. Asking whether the app may show
    /// the app's own suggestions is a question with nothing in it.
    @Test func thePermissionForOurOwnToolIsAnsweredForYou() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.permission = [
            "toolCall": ["toolCallId": "call-1", "title": "suggest_next_prompts",
                         "name": "mcp__agents__suggest_next_prompts"],
            "options": .array([
                ["optionId": "allow", "name": "Allow", "kind": "allow_once"],
                ["optionId": "reject", "name": "Reject", "kind": "reject_once"],
            ]),
        ]
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        await eventually("our own tool's question was answered for us") {
            await launcher.lastAgent?.permissionOutcome != nil
        }
        // And the agent moved off the question, which is the other assertion below.
        await eventually("the agent was not left waiting") {
            await core.agent(id)?.state != .waitingOnUser
        }

        // Nothing was ever put in front of anybody, and the agent was not left waiting.
        #expect(await core.pendingPermissionRequests().isEmpty)
        #expect(await core.agent(id)?.state != .waitingOnUser)
        let outcome = await launcher.lastAgent?.permissionOutcome
        #expect(outcome?["outcome"]?["optionId"]?.stringValue == "allow")
    }

    /// Any other tool is still the user's to allow.
    @Test func everyOtherToolIsStillAsked() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.permission = [
            "toolCall": ["toolCallId": "call-1", "title": "Delete everything", "name": "rm_rf"],
            "options": .array([["optionId": "allow", "name": "Allow", "kind": "allow_once"]]),
        ]
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        await eventually("the question reached the daemon") {
            await core.pendingPermissionRequests().count == 1
        }

        #expect(await core.pendingPermissionRequests().count == 1)
    }

    /// The row above the prompt is what the call looks like. A line in the transcript
    /// saying it happened would be the same thing twice.
    @Test func theCallItselfIsNotDrawnInTheTranscript() {
        let ours = ToolCall(toolCallID: "1", title: "suggest_next_prompts",
                            name: "mcp__agents__suggest_next_prompts")
        // What the Claude adapter sends next: the same call, finished, carrying
        // neither the name nor the title. Alone it draws as "Tool call", which is
        // exactly what appeared on screen the first time this shipped.
        let oursFinished = ToolCall(toolCallID: "1", title: "Tool call", status: "completed")
        let theirs = ToolCall(toolCallID: "2", title: "Read a file", name: "read_file")
        let items = TranscriptEntry.display([
            TranscriptEntry(kind: .agentMessage(messageID: nil, text: "Done.", blocks: [])),
            TranscriptEntry(kind: .toolCall(ours)),
            TranscriptEntry(kind: .toolCallUpdate(oursFinished)),
            TranscriptEntry(kind: .toolCall(theirs)),
        ])
        let drawn = items.compactMap { item -> [ToolCall]? in
            if case .toolRun(_, let calls) = item { return calls }
            return nil
        }.flatMap { $0 }
        #expect(drawn.map(\.name) == ["read_file"])
    }
}
