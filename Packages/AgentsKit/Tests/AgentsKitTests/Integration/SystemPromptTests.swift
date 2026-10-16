import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The briefing and persona as system prompt, where the runtime takes one (#1080), so the
/// title a runtime makes from the first prompt is about the person's words.
@Suite("Our words as system prompt", .timeLimit(.minutes(1)))
struct SystemPromptTests {
    private let persona = "---\nname: Owner\n---\nYou own the product. Write issues, not code."

    private func folders() throws -> (locations: StoreLocations, work: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsSystemPromptTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        for folder in [work, home] {
            try FileManager.default.createDirectory(at: Persona.folder(in: folder), withIntermediateDirectories: true)
        }
        try persona.write(to: Persona.folder(in: work).appending(path: "owner.md"), atomically: true, encoding: .utf8)
        var locations = StoreLocations(root: root.appending(path: "store"))
        locations.personalHome = home
        return (locations, work)
    }

    private func core(_ launcher: FakeLauncher, _ locations: StoreLocations) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                   discovery: .findsEverything, launcher: launcher)
    }

    private func sentTexts(_ agent: FakeACPAgent?) async -> [String] {
        (await agent?.promptContent?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
    }

    @Test func claudeIsBriefedInItsSystemPromptAndItsFirstPromptIsThePersonsWords() async throws {
        let (locations, work) = try folders()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "Remove the recap section",
                                            persona: "owner"))
        await eventually("the first prompt was sent") { await launcher.lastAgent?.promptContent != nil }

        let meta = await launcher.lastAgent?.newSessionParams?["_meta"]
        #expect(meta?["systemPrompt"]?["append"]?.stringValue
                == Briefing.asSent(to: "claude") + "\n\nYou own the product. Write issues, not code.")
        #expect(await sentTexts(launcher.lastAgent) == ["Remove the recap section"])
        await settled(core, id)
    }

    @Test func grokIsBriefedInItsRulesBeforeTheToolCards() async throws {
        let (locations, work) = try folders()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations)
        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "fix it"))
        await eventually("the first prompt was sent") { await launcher.lastAgent?.promptContent != nil }

        let rules = await launcher.lastAgent?.newSessionParams?["_meta"]?["rules"]?.stringValue ?? ""
        // Grok cannot move folders (053), so its briefing names no move tools.
        let briefing = Briefing.text(for: ToolPolicyCatalog.grok, movesItself: false,
                                     naming: .init(runtime: "Grok", person: PersonSettings().effectiveName()))
        #expect(rules.hasPrefix(briefing + "\n\n"))
        #expect(rules.contains(AppToolPreface.rules()))
        #expect(await sentTexts(launcher.lastAgent) == ["fix it"])
        await settled(core, id)
    }

    @Test func aPickedUpClaudeSessionIsGivenItsSystemPromptAgain() async throws {
        let (locations, work) = try folders()
        let store = try AgentStore(locations: locations)
        var wasRunning = Agent(runtimeID: "claude", cwd: work, state: .running, runtimeSessionID: "s1")
        wasRunning.persona = "owner"
        try await store.save(wasRunning)

        let launcher = FakeLauncher()
        let core = try core(launcher, locations)
        await core.pickUpAfterRestart(await core.recover())
        await eventually("the conversation was continued") {
            await launcher.lastAgent?.continuedSessionParams != nil
        }

        let append = await launcher.lastAgent?.continuedSessionParams?["_meta"]?["systemPrompt"]?["append"]?.stringValue
        #expect(append == Briefing.asSent(to: "claude") + "\n\nYou own the product. Write issues, not code.")
        await settled(core, wasRunning.id)
    }

    @Test func aDraftMadeWithoutThePersonaIsLetGoAndOneWithTheSameWordsIsUsed() async throws {
        let (locations, work) = try folders()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations)

        let plain = try await core.options(.init(runtimeID: "claude", cwd: work))
        let first = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go", draftID: plain.draftID))
        await settled(core, first)
        #expect(launcher.launchCount == 1, "the draft's words were the start's")

        let form = try await core.options(.init(runtimeID: "claude", cwd: work))
        let second = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go", draftID: form.draftID,
                                                persona: "owner"))
        await eventually("the persona's session was made") {
            await launcher.lastAgent?.newSessionParams?["_meta"]?["systemPrompt"]?["append"]?.stringValue?
                .hasSuffix("Write issues, not code.") == true
        }
        #expect(launcher.launchCount == 3, "a session for the persona, not the draft made before it was picked")
        await settled(core, second)
    }

    @Test func cursorIsBriefedInItsFirstPromptAndKeepsThePersonsTitleUntilTheSecond() async throws {
        let (locations, work) = try folders()
        var script = FakeACPAgent.Script()
        script.title = "Agent instructions and guidelines"
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "Remove the recap section"))
        await settled(core, id)

        #expect(await sentTexts(launcher.lastAgent) == [Briefing.asSent(to: "cursor"), "Remove the recap section"])
        #expect(await launcher.lastAgent?.newSessionParams?["_meta"]?["systemPrompt"] == nil)
        #expect(await core.agent(id)?.title == "Remove the recap section")

        try await core.prompt(.init(agentID: id, text: "and the chart"))
        await eventually("the runtime's title is taken from the second turn") {
            await core.agent(id)?.title == "Agent instructions and guidelines"
        }
        await settled(core, id)
    }
}
