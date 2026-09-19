import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The runtime's own list is the only way to find work started somewhere else: a
/// session from a terminal yesterday, in a folder this app knows.
@Suite("Sessions the app did not start", .timeLimit(.minutes(1)))
struct SessionHousekeepingTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsSessionTests-\(UUID().uuidString)", isDirectory: true)
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

    private func script(work: URL, sessions: [JSONValue]) -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.sessions = sessions
        script.sessionCapabilities = ["close": [:], "list": [:], "delete": [:], "fork": [:]]
        return script
    }

    @Test func theRuntimesOwnSessionsAreOfferedWithTheirTitles() async throws {
        let (locations, work) = try temporary()
        let sessions: [JSONValue] = [
            ["sessionId": "s1", "cwd": .string(work.path), "title": "Left over from yesterday",
             "updatedAt": "2026-09-18T10:00:00.000Z"],
        ]
        let core = try core(FakeLauncher(script: script(work: work, sessions: sessions)),
                            locations: locations)

        let listed = try await core.listRuntimeSessions(runtimeID: "claude", cwd: work)
        #expect(listed.count == 1)
        #expect(listed.first?.title == "Left over from yesterday")
        #expect(listed.first?.updatedAt != nil, "when it was last touched")
        #expect(listed.first?.isHeld == false)
    }

    @Test func aSessionWeAlreadyHoldIsFlaggedRatherThanHidden() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher(script: script(work: work, sessions: []))
        let first = try core(launcher, locations: locations)

        let id = try await first.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        try await Task.sleep(for: .milliseconds(200))
        let sessionID = try #require(await first.agent(id)?.runtimeSessionID)

        // The same session now comes back in the runtime's list.
        let second = FakeLauncher(script: script(work: work,
                                                 sessions: [["sessionId": .string(sessionID),
                                                             "cwd": .string(work.path)]]))
        let reopened = try core(second, locations: locations)
        await reopened.loadFromDisk()
        let listed = try await reopened.listRuntimeSessions(runtimeID: "claude", cwd: work)
        #expect(listed.first?.isHeld == true, "the list is the truth about the runtime")
    }

    @Test func adoptingOneMakesAnOrdinaryAgent() async throws {
        let (locations, work) = try temporary()
        var script = script(work: work, sessions: [])
        // What `session/load` replays is the transcript, in this one case.
        script.replayOnLoad = [FakeACPAgent.chunk("Something said yesterday")]
        let core = try core(FakeLauncher(script: script), locations: locations)

        let id = try await core.adopt(runtimeID: "claude", sessionID: "s1", cwd: work)
        try await Task.sleep(for: .milliseconds(300))

        let agent = await core.agent(id)
        #expect(agent?.runtimeSessionID == "s1")
        let page = try await core.transcript(.init(agentID: id))
        #expect(page.entries.compactMap(\.text).contains("Something said yesterday"),
                "the replay is the history we never had")
    }

    @Test func adoptingTheSameSessionTwiceIsTheSameAgent() async throws {
        let (locations, work) = try temporary()
        let core = try core(FakeLauncher(script: script(work: work, sessions: [])), locations: locations)

        let first = try await core.adopt(runtimeID: "claude", sessionID: "s1", cwd: work)
        let second = try await core.adopt(runtimeID: "claude", sessionID: "s1", cwd: work)
        #expect(first == second)
    }

    @Test func branchingLeavesTheOriginalAlone() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher(script: script(work: work, sessions: []))
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "the first thing"))
        try await Task.sleep(for: .milliseconds(300))
        let branch = try await core.fork(agentID: id)
        try await Task.sleep(for: .milliseconds(300))

        #expect(branch != id)
        let original = await core.agent(id)
        let copy = await core.agent(branch)
        #expect(original?.runtimeSessionID != copy?.runtimeSessionID)
        let copied = try await core.transcript(.init(agentID: branch))
        #expect(copied.entries.compactMap(\.text).contains("the first thing"),
                "the history so far is ours, so the branch starts with it")
        let untouched = try await core.transcript(.init(agentID: id))
        #expect(untouched.entries.compactMap(\.text).contains("the first thing"))
    }

    @Test func deletingNeedsToBeMeant() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher(script: script(work: work, sessions: []))
        let core = try core(launcher, locations: locations)

        await #expect(throws: JSONRPCError.self) {
            try await core.deleteRuntimeSession(runtimeID: "claude", sessionID: "s1", confirmed: false)
        }
        try await core.deleteRuntimeSession(runtimeID: "claude", sessionID: "s1", confirmed: true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await launcher.lastAgent?.deletedSessions == ["s1"])
    }

    @Test func aRuntimeThatCannotDoItIsNotAskedTo() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        // Copilot: no fork, no delete, no resume.
        script.sessionCapabilities = ["close": [:], "list": [:]]
        let core = try core(FakeLauncher(script: script), locations: locations)

        let id = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))
        try await Task.sleep(for: .milliseconds(200))

        await #expect(throws: JSONRPCError.self) { _ = try await core.fork(agentID: id) }
        await #expect(throws: (any Error).self) {
            try await core.deleteRuntimeSession(runtimeID: "copilot", sessionID: "s1", confirmed: true)
        }
    }
}
