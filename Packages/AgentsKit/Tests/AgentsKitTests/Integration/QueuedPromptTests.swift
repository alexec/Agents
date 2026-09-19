import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

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
        await eventually("the first turn is in flight") { await core.agent(id)?.state == .running }
        #expect(await core.agent(id)?.state == .running)

        // This used to throw. It waits now.
        try await core.prompt(.init(agentID: id, text: "two"))
        #expect(await core.agent(id)?.queuedPrompts.map(\.text) == ["two"])

        // Both turns on the record, which is what the last assertion reads. An empty
        // queue beside a finished state is also true of the moment `sendNextQueued`
        // takes the prompt off the queue and before `beginTurn` records it, so waiting
        // on those two would sometimes be waiting for a turn that has not begun.
        await eventually("both prompts were said") {
            (try? await texts(core, id)) == ["one", "two"]
        }
        await eventually("the queue drained and the second turn ended") {
            guard let agent = await core.agent(id) else { return false }
            return agent.queuedPrompts.isEmpty && agent.state == .finished
        }
        #expect(await core.agent(id)?.queuedPrompts.isEmpty == true)
        #expect(await core.agent(id)?.state == .finished)
        #expect(try await texts(core, id) == ["one", "two"])
    }

    @Test func theyGoInTheOrderTheyWereTypedIn() async throws {
        let (locations, work) = try temporary()
        let core = try core(slowLauncher(.milliseconds(250)), locations: locations)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "one"))
        await eventually("the first turn is in flight") { await core.agent(id)?.state == .running }
        try await core.prompt(.init(agentID: id, text: "two"))
        try await core.prompt(.init(agentID: id, text: "three"))
        #expect(await core.agent(id)?.queuedPrompts.map(\.text) == ["two", "three"])

        await eventually("all three turns ran") {
            (try? await texts(core, id)) == ["one", "two", "three"]
        }
        #expect(await core.agent(id)?.queuedPrompts.isEmpty == true)
        #expect(try await texts(core, id) == ["one", "two", "three"],
                "each queued prompt is a turn of its own, in the order it was typed")
    }

    /// The point of showing the queue is being able to change your mind about it.
    @Test func oneCanBeTakenBackBeforeItsTurnComes() async throws {
        let (locations, work) = try temporary()
        let core = try core(slowLauncher(), locations: locations)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "one"))
        await eventually("the first turn is in flight") { await core.agent(id)?.state == .running }
        try await core.prompt(.init(agentID: id, text: "two"))
        try await core.prompt(.init(agentID: id, text: "three"))

        let unwanted = try #require(await core.agent(id)?.queuedPrompts.first { $0.text == "two" })
        try await core.unqueue(.init(agentID: id, promptID: unwanted.id))
        #expect(await core.agent(id)?.queuedPrompts.map(\.text) == ["three"])

        await eventually("the remaining prompt ran and the withdrawn one did not") {
            (try? await texts(core, id)) == ["one", "three"]
        }
        #expect(try await texts(core, id) == ["one", "three"])
    }

    /// Stop means stop. What was queued is kept where the user can see it rather than
    /// sent on behind them, and rather than silently dropped.
    @Test func stoppingTheAgentDoesNotSendWhatIsQueued() async throws {
        let (locations, work) = try temporary()
        let core = try core(slowLauncher(.seconds(2)), locations: locations)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "one"))
        await eventually("the first turn is in flight") { await core.agent(id)?.state == .running }
        try await core.prompt(.init(agentID: id, text: "two"))
        try await core.stop(id)
        await eventually("the agent stopped") { await core.agent(id)?.state == .stopped }

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
            await eventually("the first turn is in flight") { await core.agent(id)?.state == .running }
            try await core.prompt(.init(agentID: id, text: "two"))
            try await core.stop(id)
            // Wait for the record on disk, not the one in memory. The other core below
            // reads the file, and the file is written a moment after the state changes.
            await eventually("the queue reached the file") {
                let store = try? AgentStore(locations: locations)
                let reread = try? await store?.load(id)
                return reread?.queuedPrompts.map(\.text) == ["two"]
            }
        }

        let reopened = try core(FakeLauncher(), locations: locations)
        await reopened.loadFromDisk()
        #expect(await reopened.agent(id)?.queuedPrompts.map(\.text) == ["two"])
    }

    /// Two callers want to send the same waiting prompt: the user, typing as a turn
    /// ends, and the turn itself, draining the queue behind them.
    ///
    /// Starting a runtime is a long await, and nothing said "already going" until the
    /// turn task existed, so both could get inside it and the same words went to two
    /// runtimes — two turns, twice the cost, and an answer to a question asked once.
    /// Found by a test that queued a prompt in exactly that window.
    @Test func theSameWaitingPromptIsNotSentTwice() async throws {
        let (locations, work) = try temporary()
        let launcher = slowLauncher(.milliseconds(600))
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "one"))
        await eventually("the first turn is in flight") { await core.agent(id)?.state == .running }
        // Queued rather than sent, because a turn is in flight. Stopping then leaves
        // it exactly where it is — stop means stop, and the queue stays put — which is
        // an idle agent with something waiting and nothing about to drain it.
        try await core.prompt(.init(agentID: id, text: "two"))
        try await core.stop(id)
        await eventually("the agent stopped with its queue intact") {
            await core.agent(id)?.state == .stopped
        }
        #expect(await core.agent(id)?.queuedPrompts.map(\.text) == ["two"])

        // Both callers at once, which is what the window amounts to.
        async let first: Void = core.sendNextQueued(to: id)
        async let second: Void = core.sendNextQueued(to: id)
        _ = try await (first, second)

        @Sendable func timesTwoWasSent() async -> Int {
            var count = 0
            for fake in launcher.allAgents {
                guard let blocks = await fake.promptContent?.arrayValue else { continue }
                if blocks.compactMap({ $0["text"]?.stringValue }).contains("two") { count += 1 }
            }
            return count
        }

        // Two halves, and they need different treatment. That it was sent at all is a
        // condition, so it is waited for; that it was not *also* sent a second time is
        // an absence, and the only way to test an absence is to give the second one
        // time to turn up. The queue emptying is not the signal — it empties when the
        // prompt is taken off it, which is before the prompt reaches any runtime.
        await eventually("the waiting prompt was sent") { await timesTwoWasSent() >= 1 }
        try await Task.sleep(for: .milliseconds(300))

        var sent: [[String]] = []
        for fake in launcher.allAgents {
            guard let blocks = await fake.promptContent?.arrayValue else { continue }
            sent.append(blocks.compactMap { $0["text"]?.stringValue })
        }
        #expect(sent.filter { $0.contains("two") }.count == 1)
        #expect(await core.agent(id)?.queuedPrompts.isEmpty == true)
    }
}
