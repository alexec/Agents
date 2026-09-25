import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What a server's daemon says about itself, and how it is asked to go (037).
///
/// The window updates a server only when nothing is mid-turn, and removes one after
/// saying how many agents that will stop. Both numbers come from here.
@Suite("A daemon's status and quitting")
struct DaemonStatusQuitTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsStatusTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func core(_ launcher: FakeLauncher, locations: StoreLocations) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                   discovery: .findsEverything, launcher: launcher)
    }

    private func status(_ core: DaemonCore) async throws -> DaemonAPI.DaemonStatus {
        let result = await core.handle(method: DaemonAPI.Method.daemonStatus, params: nil)
        return try result.get().decode(DaemonAPI.DaemonStatus.self)
    }

    @Test func anIdleDaemonHasNothingInFlight() async throws {
        let (locations, _) = try temporary()
        let core = try core(FakeLauncher(), locations: locations)
        let now = try await status(core)
        #expect(now.turnsInFlight == 0)
        #expect(now.agentsLive == 0)
    }

    @Test func anAgentMidTurnIsInFlightAndLive() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.turnDelay = .seconds(30)
        let core = try core(FakeLauncher(script: script), locations: locations)
        _ = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "take a while"))
        await eventually("the turn has begun") { (try? await status(core).turnsInFlight) == 1 }
        #expect(try await status(core).agentsLive == 1)
    }

    @Test func quittingIsRefusedWhileATurnIsInFlight() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.turnDelay = .seconds(30)
        let core = try core(FakeLauncher(script: script), locations: locations)
        _ = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "take a while"))
        await eventually("the turn has begun") { (try? await status(core).turnsInFlight) == 1 }

        let result = await core.handle(method: DaemonAPI.Method.daemonQuit,
                                       params: try JSONValue.encoding(DaemonAPI.QuitRequest(stopAgents: false)))
        guard case .failure(let error) = result else {
            Issue.record("quit went ahead under a running turn")
            return
        }
        #expect(error.code == DaemonAPI.Failure.busy)
        #expect(await core.quitRequested == false)
    }

    @Test func quittingWhenIdleEndsTheRun() async throws {
        let (locations, _) = try temporary()
        let core = try core(FakeLauncher(), locations: locations)
        await core.setExitsWhenIdle(false)
        let run = Task { await core.runUntilIdle(grace: .seconds(60), checkEvery: .milliseconds(20)) }

        let result = await core.handle(method: DaemonAPI.Method.daemonQuit,
                                       params: try JSONValue.encoding(DaemonAPI.QuitRequest(stopAgents: false)))
        #expect((try? result.get()) != nil)
        // A serving daemon never leaves for being idle; asked to, it goes at once rather
        // than after the grace period meant for a window that is only reopening.
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await run.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(finished)
    }

    @Test func quittingWithStopAgentsStopsThemFirst() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.turnDelay = .seconds(30)
        let core = try core(FakeLauncher(script: script), locations: locations)
        let agentID = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "take a while"))
        await eventually("the turn has begun") { (try? await status(core).turnsInFlight) == 1 }

        let result = await core.handle(method: DaemonAPI.Method.daemonQuit,
                                       params: try JSONValue.encoding(DaemonAPI.QuitRequest(stopAgents: true)))
        #expect((try? result.get()) != nil)
        #expect(await core.agent(agentID)?.state == .stopped)
        #expect(await core.quitRequested)
    }
}
