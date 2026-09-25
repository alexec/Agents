import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A start sent again with the same request id is the same start (029). A phone whose
/// reply was lost on the way back cannot tell a start that never happened from one that
/// did, so it sends again — and that must never be the work twice.
@Suite("Starting once, however often it is asked", .timeLimit(.minutes(1)))
struct StartIdempotencyTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsStartOnceTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func core(_ launcher: FakeLauncher, _ locations: StoreLocations) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                   discovery: .findsEverything, launcher: launcher)
    }

    private func agentsWith(_ requestID: UUID, in core: DaemonCore) async -> [Agent] {
        await core.agents.values.filter { $0.startRequestID == requestID }
    }

    @Test func theSameRequestTwiceIsOneAgent() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations)
        let requestID = UUID()
        let request = DaemonAPI.StartRequest(runtimeID: "claude", cwd: work, prompt: "go", requestID: requestID)

        let first = try await core.start(request)
        let second = try await core.start(request)

        #expect(first == second)
        #expect(await agentsWith(requestID, in: core).count == 1)
        #expect(launcher.launchCount == 1, "no second runtime for a start that already happened")
        #expect(await core.agent(first)?.startRequestID == requestID)
    }

    @Test func aRepeatWhileTheFirstIsStillStartingWaitsForIt() async throws {
        let (locations, work) = try temporary()
        var slow = FakeACPAgent.Script()
        slow.handshakeDelay = .milliseconds(300)
        let launcher = FakeLauncher(script: slow)
        let core = try core(launcher, locations)
        let request = DaemonAPI.StartRequest(runtimeID: "claude", cwd: work, prompt: "go", requestID: UUID())

        async let first = core.start(request)
        async let second = core.start(request)
        let (a, b) = try await (first, second)

        #expect(a == b)
        #expect(launcher.launchCount == 1)
    }

    @Test func aRepeatAfterTheDaemonRestartedFindsTheAgentOnDisk() async throws {
        let (locations, work) = try temporary()
        let requestID = UUID()
        let store = try AgentStore(locations: locations)
        let made = Agent(runtimeID: "claude", cwd: work, state: .finished, endedReason: .endTurn,
                         startRequestID: requestID)
        try await store.save(made)

        let launcher = FakeLauncher()
        let core = try core(launcher, locations)
        await core.loadFromDisk()
        let answered = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go",
                                                  requestID: requestID))

        #expect(answered == made.id)
        #expect(launcher.launchCount == 0)
    }

    @Test func aRefusedStartRecordsNothingSoARetryCanStart() async throws {
        let (locations, work) = try temporary()
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        let limits = LimitStore(locations: locations)
        try limits.save(CostLimits(daily: Cost(amount: 0, currency: "USD")))
        let core = try core(FakeLauncher(), locations)
        let requestID = UUID()
        let request = DaemonAPI.StartRequest(runtimeID: "claude", cwd: work, prompt: "go", requestID: requestID)

        await #expect(throws: JSONRPCError.self) { try await core.start(request) }
        #expect(await agentsWith(requestID, in: core).isEmpty)

        try limits.save(CostLimits())
        let started = try await core.start(request)
        #expect(await agentsWith(requestID, in: core).map(\.id) == [started])
    }

    @Test func aStartWithNoRequestIDIsAStartEachTime() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher()
        let core = try core(launcher, locations)
        let request = DaemonAPI.StartRequest(runtimeID: "claude", cwd: work, prompt: "go")

        let first = try await core.start(request)
        let second = try await core.start(request)

        #expect(first != second)
        #expect(launcher.launchCount == 2)
    }
}
