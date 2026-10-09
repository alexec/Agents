import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A turn the app started by itself that ended without saying how it went (#149).
///
/// A block clearing, its time coming round, or a wait timing out starts the agent again
/// with the last turn's report still on it, because nothing the person did cleared it.
/// That report is the last turn's account, not this one's: a silent resumed turn is
/// accounted for afresh, as any other is (#479), and nothing is asked.
@Suite("A silent turn after the app resumed an agent", .timeLimit(.minutes(1)))
struct ResumedSilenceTests {
    /// Which agent each test token speaks for, bound again before every call: a fake
    /// agent's session drops its token when its turn ends. See `BlockedTests`.
    private final class Callers: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String: UUID] = [:]
        subscript(token: String) -> UUID? {
            get { lock.withLock { ids[token] } }
            set { lock.withLock { ids[token] = newValue } }
        }
    }
    private let callers = Callers()

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { date } }
        func advance(minutes: Double) { lock.withLock { date = date.addingTimeInterval(minutes * 60) } }
    }

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsResumedSilence-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work.resolvingSymlinksInPath()))
    }

    private func makeCore(_ locations: StoreLocations, _ launcher: FakeLauncher,
                          clock: Clock? = nil) async throws -> DaemonCore {
        let core = if let clock {
            DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                       discovery: .findsEverything, launcher: launcher, now: { clock.now })
        } else {
            DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                       discovery: .findsEverything, launcher: launcher)
        }
        await core.loadFromDisk()
        return core
    }

    /// A turn that lasts until the test opens `gate`.
    private static func held(_ gate: TurnGate) -> FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.gate = gate
        return script
    }

    private func agent(_ core: DaemonCore, in folder: URL, _ title: String) async throws -> (UUID, String) {
        let id = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: folder, prompt: title))
        let token = UUID().uuidString
        callers[token] = id
        await core.bindAppToken(token, to: id)
        return (id, token)
    }

    @discardableResult
    private func finish(_ core: DaemonCore, _ token: String, _ outcome: String, _ message: String,
                        minutes: Int? = nil) async throws -> String {
        if let id = callers[token] { await core.bindAppToken(token, to: id) }
        return try await core.finishTurn(.init(token: token, outcome: outcome, message: message,
                                               prompts: [], waitingOn: nil,
                                               checkAgainInMinutes: minutes))
    }

    private func appPrompts(_ core: DaemonCore, _ id: UUID) async throws -> [String] {
        try await core.transcript(.init(agentID: id, before: nil, limit: 500)).entries.compactMap {
            if case .userMessage(let text, _, .app) = $0.kind { return text } else { return nil }
        }
    }

    /// How many times the app asked how a turn went: the old question named the tool.
    private func asks(_ core: DaemonCore, _ id: UUID) async throws -> Int {
        try await appPrompts(core, id).count { $0.contains(AppTool.finishTurn) }
    }

    /// Long enough for anything queued behind a settle to have shown itself.
    private func quiet() async throws { try await Task.sleep(for: .milliseconds(300)) }

    // MARK: A block's time coming round

    /// The issue's case whole: blocked with a time to check again, resumed when it
    /// comes, and the resumed turn ends without a word. Nothing is asked, and the old
    /// block gives way to the resumed turn's own ending.
    @Test func aSilentTurnAfterTheTimeCameIsAccountedForWithoutAsking() async throws {
        let (locations, work) = try temporary()
        let gate = TurnGate()
        let core = try await makeCore(locations, FakeLauncher(script: .init(), then: [Self.held(gate)]))
        let (id, token) = try await agent(core, in: work, "Lead")
        try await finish(core, token, "blocked", "Waiting on CI.", minutes: 1)
        gate.open()
        await settled(core, id, "the first turn ended blocked")
        let at = try #require(await core.agent(id)?.report?.block?.checkAgainAt)

        await core.tickWorkflows(now: at.addingTimeInterval(1))
        await eventually("the resumed turn ended under an account of its own") {
            guard let agent = await core.agent(id) else { return false }
            return agent.state == .finished && agent.report?.outcome == .done
        }
        try await quiet()
        let after = try #require(await core.agent(id))
        #expect(after.report?.message == DerivedEnding.silentDone)
        #expect(after.endingIsUnaccountedFor == false)
        #expect(try await asks(core, id) == 0)
    }

    /// A resumed turn that does report is not asked: the new report is this turn's.
    @Test func aResumedTurnThatReportsIsNotAsked() async throws {
        let (locations, work) = try temporary()
        let first = TurnGate(), resumed = TurnGate()
        let core = try await makeCore(locations, FakeLauncher(script: .init(),
                                                               then: [Self.held(first), Self.held(resumed)]))
        let (id, token) = try await agent(core, in: work, "Lead")
        try await finish(core, token, "blocked", "Waiting on CI.", minutes: 1)
        first.open()
        await settled(core, id, "the first turn ended blocked")
        let at = try #require(await core.agent(id)?.report?.block?.checkAgainAt)

        await core.tickWorkflows(now: at.addingTimeInterval(1))
        await eventually("the resumed turn is running") { await core.agent(id)?.state == .running }
        try await finish(core, token, "done", "CI passed.")
        resumed.open()
        await settled(core, id, "the resumed turn ended")
        try await quiet()
        #expect(try await asks(core, id) == 0)
        #expect(await core.agent(id)?.report?.message == "CI passed.")
    }

    // MARK: A wait timing out

    /// The same through the other road in: a wait on events whose deadline passes after
    /// the turn ended, under a report the agent gave before it ended.
    @Test func aSilentTurnAfterAWaitTimedOutIsAccountedForWithoutAsking() async throws {
        let clock = Clock()
        let (locations, work) = try temporary()
        let gate = TurnGate()
        let core = try await makeCore(locations, FakeLauncher(script: .init(), then: [Self.held(gate)]),
                                      clock: clock)
        await core.useForEvents(holdLimit: .milliseconds(100))
        let (id, token) = try await agent(core, in: work, "Patient")
        if let bound = callers[token] { await core.bindAppToken(token, to: bound) }
        _ = try await core.waitForEvent(.init(token: token, events: ["custom.never"], where: nil,
                                              from: nil, untilMinutes: 1))
        try await finish(core, token, "partly_done", "Half of it; waiting on the rest.")
        gate.open()
        await settled(core, id, "the first turn ended")

        clock.advance(minutes: 2)
        await core.eventWaitDeadlinesPassed()
        await eventually("the woken turn ended under an account of its own") {
            await core.agent(id)?.report?.outcome == .done
        }
        #expect(try await appPrompts(core, id).contains { $0.hasPrefix("Your wait for custom.never timed out at ") })
        await settled(core, id, "the woken turn ended")
        try await quiet()
        #expect(try await asks(core, id) == 0)
    }
}
