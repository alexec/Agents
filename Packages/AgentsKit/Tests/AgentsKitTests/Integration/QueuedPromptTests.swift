import Foundation
import Testing
@testable import AgentsKit

/// Typing the next thing before the agent has finished the last one.
///
/// The queue is the daemon's rather than the runtime's, so these are the tests that
/// say so: nothing reaches a runtime mid-turn, the order is the order it was typed
/// in, and nothing typed is ever thrown away without being said out loud.
@Suite("Queueing what you type while it works", .timeLimit(.minutes(1)))
struct QueuedPromptTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsQueueTests-\(UUID().uuidString)", isDirectory: true)
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

    /// A turn slow enough that a second prompt lands in the middle of it.
    private func slowLauncher(_ delay: Duration = .milliseconds(400)) -> FakeLauncher {
        var script = FakeACPAgent.Script()
        script.turnDelay = delay
        return FakeLauncher(script: script)
    }

    private func texts(_ core: DaemonCore, _ id: UUID) async throws -> [String] {
        try await core.transcript(.init(agentID: id)).entries.compactMap { entry in
            if case .userMessage(let text, _) = entry.kind { return text }
            return nil
        }
    }

    @Test func aPromptSentWhileItWorksWaitsRatherThanBeingRefused() async throws {
        let (locations, work) = try temporary()
        let core = try core(slowLauncher(), locations: locations)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "one"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await core.agent(id)?.state == .running)

        // This used to throw. It waits now.
        try await core.prompt(.init(agentID: id, text: "two"))
        #expect(await core.agent(id)?.queuedPrompts.map(\.text) == ["two"])

        try await Task.sleep(for: .seconds(2))
        #expect(await core.agent(id)?.queuedPrompts.isEmpty == true)
        #expect(await core.agent(id)?.state == .finished)
        #expect(try await texts(core, id) == ["one", "two"])
    }

    @Test func theyGoInTheOrderTheyWereTypedIn() async throws {
        let (locations, work) = try temporary()
        let core = try core(slowLauncher(.milliseconds(250)), locations: locations)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "one"))
        try await Task.sleep(for: .milliseconds(60))
        try await core.prompt(.init(agentID: id, text: "two"))
        try await core.prompt(.init(agentID: id, text: "three"))
        #expect(await core.agent(id)?.queuedPrompts.map(\.text) == ["two", "three"])

        try await Task.sleep(for: .seconds(3))
        #expect(await core.agent(id)?.queuedPrompts.isEmpty == true)
        #expect(try await texts(core, id) == ["one", "two", "three"],
                "each queued prompt is a turn of its own, in the order it was typed")
    }

    /// The point of showing the queue is being able to change your mind about it.
    @Test func oneCanBeTakenBackBeforeItsTurnComes() async throws {
        let (locations, work) = try temporary()
        let core = try core(slowLauncher(), locations: locations)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "one"))
        try await Task.sleep(for: .milliseconds(60))
        try await core.prompt(.init(agentID: id, text: "two"))
        try await core.prompt(.init(agentID: id, text: "three"))

        let unwanted = try #require(await core.agent(id)?.queuedPrompts.first { $0.text == "two" })
        try await core.unqueue(.init(agentID: id, promptID: unwanted.id))
        #expect(await core.agent(id)?.queuedPrompts.map(\.text) == ["three"])

        try await Task.sleep(for: .seconds(2))
        #expect(try await texts(core, id) == ["one", "three"])
    }

    /// Stop means stop. What was queued is kept where the user can see it rather than
    /// sent on behind them, and rather than silently dropped.
    @Test func stoppingTheAgentDoesNotSendWhatIsQueued() async throws {
        let (locations, work) = try temporary()
        let core = try core(slowLauncher(.seconds(2)), locations: locations)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "one"))
        try await Task.sleep(for: .milliseconds(100))
        try await core.prompt(.init(agentID: id, text: "two"))
        try await core.stop(id)
        try await Task.sleep(for: .seconds(1))

        #expect(await core.agent(id)?.state == .stopped)
        #expect(await core.agent(id)?.queuedPrompts.map(\.text) == ["two"],
                "kept, so the user can send it or throw it away themselves")
        #expect(try await texts(core, id) == ["one"], "nothing was sent on behind them")

        let notes = try await core.transcript(.init(agentID: id)).entries.compactMap { entry -> String? in
            if case .runtimeNote(let text) = entry.kind { return text }
            return nil
        }
        #expect(notes.contains { $0.contains("not sent") }, "and they are told, rather than left to notice")
    }

    /// The queue is on the agent's record, so the daemon going idle and coming back
    /// does not lose what somebody typed.
    @Test func theQueueIsOnTheRecordAndSurvivesADaemonRestart() async throws {
        let (locations, work) = try temporary()
        let id: UUID
        do {
            let core = try core(slowLauncher(.seconds(2)), locations: locations)
            id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "one"))
            try await Task.sleep(for: .milliseconds(100))
            try await core.prompt(.init(agentID: id, text: "two"))
            try await core.stop(id)
            try await Task.sleep(for: .milliseconds(300))
        }

        let reopened = try core(FakeLauncher(), locations: locations)
        await reopened.loadFromDisk()
        #expect(await reopened.agent(id)?.queuedPrompts.map(\.text) == ["two"])
    }
}
