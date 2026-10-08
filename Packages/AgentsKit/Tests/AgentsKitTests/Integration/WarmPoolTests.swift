import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The warm pool (#183), driven through the real daemon with fake runtimes: a finished
/// chat keeps its runtime for the reply, within a cap, scored by how likely the reply
/// is; and a window's intent starts one ahead of the prompt.
@Suite("Warm runtimes between turns", .timeLimit(.minutes(1)))
struct WarmPoolTests {
    /// A clock the test moves, for decay, the ceiling and being away.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var time = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { time } }
        func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    }

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWarmPoolTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    private func core(_ launcher: FakeLauncher, _ locations: StoreLocations, clock: Clock,
                      cap: Int = 3) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher, now: { clock.now })
        _ = await core.setWakeSettings(WakeSettings(keepsAwake: false, graceHours: 0, warmRuntimes: cap))
        return core
    }

    /// Wait until the agent's turns are over and nothing is on its way to a runtime.
    private func settled(_ core: DaemonCore, _ id: UUID) async {
        await eventually("the agent settled") {
            guard let agent = await core.agent(id) else { return false }
            let busy = await core.isBusyForTest(id)
            let decided = await core.decidedForTest(id)
            return !agent.state.hasTurnInFlight && agent.queuedPrompts.isEmpty && !busy
                && decided
        }
    }

    /// A chat the person started and is talking in.
    private func chat(_ core: DaemonCore, _ work: URL) async throws -> UUID {
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "hello"))
        await core.notePersonPrompt(id)
        await settled(core, id)
        return id
    }

    private func isWarm(_ core: DaemonCore, _ id: UUID) async -> Bool {
        await core.isWarmForTest(id)
    }

    // MARK: The pool

    @Test func aFinishedChatKeepsItsRuntimeAndTheReplyUsesIt() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher(keepsRuntimesWarm: true)
        let clock = Clock()
        let core = try await core(launcher, locations, clock: clock)
        let id = try await chat(core, work)
        #expect(await isWarm(core, id), "kept for the reply")
        let launches = launcher.launchCount

        await core.notePersonPrompt(id)
        try await core.prompt(.init(agentID: id, text: "and again"))
        await settled(core, id)
        #expect(launcher.launchCount == launches, "the reply went straight to session/prompt")
        #expect(await isWarm(core, id), "and it is warm again after")
    }

    @Test func aWarmRuntimeIsNotWorkTheDaemonOrTheMacHolds() async throws {
        let (locations, work) = try temporary()
        let clock = Clock()
        let core = try await core(FakeLauncher(keepsRuntimesWarm: true), locations, clock: clock)
        let id = try await chat(core, work)
        #expect(await isWarm(core, id))
        #expect(await core.isHoldingAgents == false, "the daemon may exit under a warm runtime")
        #expect(await core.hasWorkInFlight == false, "nor does it keep the Mac awake")
        #expect(await core.agent(id)?.state == .finished, "the agent stays finished")
    }

    @Test func aWarmHelperTakesNoRunningPlace() async throws {
        let (locations, work) = try temporary()
        let clock = Clock()
        let core = try await core(FakeLauncher(keepsRuntimesWarm: true), locations, clock: clock)
        let starter = try await chat(core, work)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "help"))
        await core.mutateForTest(id) { $0.startedByAgent = starter }
        await core.notePersonPrompt(id)
        await settled(core, id)
        #expect(await isWarm(core, id), "a helper the person chats in is kept too")
        #expect(await core.helperPlaces(in: work).hasPrefix("0 of"), "and is not running")
    }

    @Test func theCapLetsTheLowestScoreGo() async throws {
        let (locations, work) = try temporary()
        let clock = Clock()
        let core = try await core(FakeLauncher(keepsRuntimesWarm: true), locations, clock: clock, cap: 2)
        let oldest = try await chat(core, work)
        clock.advance(60)
        let watched = try await chat(core, work)
        try await core.reportPresence(.init(watching: watched, active: true), from: .mac, connection: UUID())
        clock.advance(60)
        #expect(await isWarm(core, oldest))
        #expect(await isWarm(core, watched))

        let newest = try await chat(core, work)
        #expect(await core.warm.count == 2, "never more than the cap")
        #expect(await isWarm(core, watched), "on screen is the highest")
        #expect(await isWarm(core, newest), "the newest finish outranks the oldest")
        #expect(await core.live[oldest] == nil, "the lowest score was let go")
    }

    @Test func aWorkflowsSessionIsNeverPooled() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(300)
        let clock = Clock()
        let core = try await core(FakeLauncher(script: script, keepsRuntimesWarm: true), locations, clock: clock)
        let id = try await core.start(.init(runtimeID: "cursor", cwd: work, prompt: "nightly"))
        await core.mutateForTest(id) { $0.startedByWorkflow = "nightly" }
        await settled(core, id)
        #expect(await core.warm[id] == nil)
        #expect(await core.live[id] == nil, "let go at once, as before")
    }

    @Test func aPoolOfNoneIsTheOldBehaviour() async throws {
        let (locations, work) = try temporary()
        let clock = Clock()
        let core = try await core(FakeLauncher(keepsRuntimesWarm: true), locations, clock: clock, cap: 0)
        let id = try await chat(core, work)
        #expect(await core.live[id] == nil)
    }

    // MARK: Released at once

    @Test func aPendingMoveIsNeverWarm() async throws {
        let (locations, work) = try temporary()
        let clock = Clock()
        let core = try await core(FakeLauncher(keepsRuntimesWarm: true), locations, clock: clock)
        let id = try await chat(core, work)
        #expect(await isWarm(core, id))
        await core.mutateForTest(id) {
            $0.pendingMove = PendingMove(target: .projectFolder, askedBy: .person, askedAt: clock.now)
        }
        #expect(await core.warmMismatch(try #require(await core.agent(id))) == "a move is waiting",
                "a warm runtime is not reused under a move")
        // The turn end's own decision, with the move still waiting for the runtime to go.
        await core.takeFromPoolForTest(id)
        await core.keepWarmOrRelease(id)
        #expect(await core.live[id] == nil, "a move waiting lets the runtime go at turn end")
    }

    @Test func aChangedLaunchStartsAFreshRuntime() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher(keepsRuntimesWarm: true)
        let clock = Clock()
        let core = try await core(launcher, locations, clock: clock)
        let id = try await chat(core, work)
        #expect(await isWarm(core, id))
        let launches = launcher.launchCount
        let more = work.deletingLastPathComponent().appendingPathComponent("more", isDirectory: true)
        try FileManager.default.createDirectory(at: more, withIntermediateDirectories: true)
        await core.mutateForTest(id) { $0.additionalDirectories.append(more) }
        #expect(await core.warmMismatch(try #require(await core.agent(id))) != nil)

        try await core.prompt(.init(agentID: id, text: "again"))
        await settled(core, id)
        #expect(launcher.launchCount == launches + 1, "what it started with changed, so it starts again")
    }

    @Test func stopAndArchiveLetAWarmRuntimeGo() async throws {
        let (locations, work) = try temporary()
        let clock = Clock()
        let core = try await core(FakeLauncher(keepsRuntimesWarm: true), locations, clock: clock)
        let stopped = try await chat(core, work)
        let archived = try await chat(core, work)
        let parked = try await chat(core, work)
        #expect(await core.warm.count == 3)

        try await core.stop(stopped)
        #expect(await core.live[stopped] == nil)
        try await core.archive(archived)
        #expect(await core.live[archived] == nil)
        #expect(await core.liveStateKeys(for: archived).isEmpty)
        try await core.park(parked)
        await eventually("parking lets it go") { await core.live[parked] == nil }
        #expect(await core.warm.isEmpty)
    }

    @Test func aRuntimeUpdateLetsItsWarmRuntimesGo() async throws {
        let (locations, work) = try temporary()
        let clock = Clock()
        let core = try await core(FakeLauncher(keepsRuntimesWarm: true), locations, clock: clock)
        let id = try await chat(core, work)
        await core.releaseWarm(runtimeID: "cursor", because: "cursor was updated")
        #expect(await core.live[id] == nil)
    }

    @Test func aWarmRuntimeThatDiesIsForgottenQuietly() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher(keepsRuntimesWarm: true)
        let clock = Clock()
        let core = try await core(launcher, locations, clock: clock)
        let id = try await chat(core, work)
        let session = try #require(await core.live[id])
        await session.noteExit(status: 1)
        await eventually("its death is heard") { await core.live[id] == nil }
        #expect(await core.warm[id] == nil)
        #expect(await core.agent(id)?.state == .finished, "nothing about the agent changed")

        try await core.prompt(.init(agentID: id, text: "still there?"))
        await settled(core, id)
        #expect(await core.agent(id)?.state == .finished, "the next prompt started one as before")
    }

    // MARK: Decay, the ceiling, and being away

    @Test func theCeilingLetsItGoWhateverItsScore() async throws {
        let (locations, work) = try temporary()
        let clock = Clock()
        let core = try await core(FakeLauncher(keepsRuntimesWarm: true), locations, clock: clock)
        let id = try await chat(core, work)
        try await core.reportPresence(.init(watching: id, active: true), from: .mac, connection: UUID())
        clock.advance(WarmPool.ceiling - 60)
        await core.reviseWarmPool()
        #expect(await isWarm(core, id), "on screen keeps it before the ceiling")
        clock.advance(120)
        await core.reviseWarmPool()
        #expect(await core.live[id] == nil, "and not past it")
    }

    @Test func thePoolDrainsWhenThePersonIsAway() async throws {
        let (locations, work) = try temporary()
        let clock = Clock()
        let core = try await core(FakeLauncher(keepsRuntimesWarm: true), locations, clock: clock)
        let idle = try await chat(core, work)
        let onPhone = try await chat(core, work)
        try await core.reportPresence(.init(watching: onPhone, active: true),
                                      from: .device(UUID()), connection: UUID())

        await core.machineChanged(.away(why: "locked"))
        clock.advance(60)
        await core.reviseWarmPool()
        #expect(await isWarm(core, idle), "a glance away keeps the pool")
        clock.advance(WarmPool.awayDrainsAfter)
        await core.reviseWarmPool()
        #expect(await core.live[idle] == nil, "away long enough, it drains")
        #expect(await isWarm(core, onPhone), "to what is on screen somewhere")

        await core.machineChanged(.back(why: "locked"))
        #expect(await core.personAwaySince == nil)
    }

    // MARK: Warm on intent

    @Test func prewarmStartsOneRuntimeAndThePromptUsesIt() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher(keepsRuntimesWarm: true)
        let clock = Clock()
        let core = try await core(launcher, locations, clock: clock)
        let id = try await chat(core, work)
        try await core.park(id)
        try await core.unpark(id)
        await eventually("parking let it go") { await core.live[id] == nil }
        let launches = launcher.launchCount

        try await core.prewarm(.init(agentID: id, why: .opened))
        try await core.prewarm(.init(agentID: id, why: .typing))
        try await core.prewarm(.init(agentID: id, why: .typing))
        await eventually("it warmed") { await core.warm[id] != nil }
        #expect(launcher.launchCount == launches + 1, "one start however often a window asks")
        #expect(await core.agent(id)?.state == .finished, "warming says nothing and changes nothing")

        try await core.prompt(.init(agentID: id, text: "now"))
        await settled(core, id)
        #expect(launcher.launchCount == launches + 1, "the prompt used the warmed runtime")
    }

    @Test func aPrewarmNobodyPromptsIsLetGo() async throws {
        let (locations, work) = try temporary()
        let clock = Clock()
        let core = try await core(FakeLauncher(keepsRuntimesWarm: true), locations, clock: clock)
        let id = try await chat(core, work)
        try await core.park(id)
        try await core.unpark(id)
        await eventually("parking let it go") { await core.live[id] == nil }

        try await core.prewarm(.init(agentID: id, why: .opened))
        await eventually("it warmed") { await core.warm[id] != nil }
        clock.advance(WarmPool.ceiling)
        await core.reviseWarmPool()
        #expect(await core.live[id] == nil, "nobody sent anything, so it went")
    }

    @Test func aPrewarmOfAParkedOrArchivedSessionDoesNothing() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher(keepsRuntimesWarm: true)
        let clock = Clock()
        let core = try await core(launcher, locations, clock: clock)
        let id = try await chat(core, work)
        try await core.archive(id)
        let launches = launcher.launchCount
        try await core.prewarm(.init(agentID: id, why: .opened))
        try await Task.sleep(for: .milliseconds(200))
        #expect(launcher.launchCount == launches)
    }

    // MARK: Prewarms within the cap (#202)

    /// The issue's own measure: twelve chats opened in a row, with a cap of 3.
    @Test func twelvePrewarmsNeverStartMoreThanTheCap() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher(keepsRuntimesWarm: true)
        let clock = Clock()
        let core = try await core(launcher, locations, clock: clock)
        var ids: [UUID] = []
        for _ in 0..<12 { ids.append(try await chat(core, work)) }
        await core.releaseWarm(runtimeID: "cursor", because: "a clean pool for the test")
        #expect(await core.warm.isEmpty)
        let launches = launcher.launchCount

        var most = 0
        for id in ids {
            try await core.prewarm(.init(agentID: id, why: .opened))
            most = max(most, await core.poolRuntimesForTest(ids))
        }
        #expect(await core.prewarmQueue.count <= 3, "no more wait than the cap")
        for _ in 0..<2000 {
            most = max(most, await core.poolRuntimesForTest(ids))
            if await core.prewarming.isEmpty, await core.prewarmQueue.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await core.prewarming.isEmpty, "the prewarms settled")
        #expect(most <= 3, "never more than the cap at once, starting or warm")
        #expect(await core.warm.count == 3)
        #expect(await ids.asyncCount { await core.live[$0] != nil } == 3)
        #expect(launcher.launchCount - launches <= 6, "the first three, then the newest three asks")
        for id in ids.suffix(3) { #expect(await isWarm(core, id), "the newest intent wins") }
    }

    @Test func aParkedSessionIsNotPrewarmed() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher(keepsRuntimesWarm: true)
        let clock = Clock()
        let core = try await core(launcher, locations, clock: clock)
        let id = try await chat(core, work)
        try await core.park(id)
        await eventually("parking let it go") { await core.live[id] == nil }
        let launches = launcher.launchCount
        try await core.prewarm(.init(agentID: id, why: .opened))
        try await Task.sleep(for: .milliseconds(200))
        #expect(launcher.launchCount == launches)
        #expect(await core.live[id] == nil)
    }

    @Test func aSessionOverItsSpendingLimitIsNotPrewarmed() async throws {
        let (locations, work) = try temporary()
        let launcher = FakeLauncher(keepsRuntimesWarm: true)
        let clock = Clock()
        let core = try await core(launcher, locations, clock: clock)
        let id = try await chat(core, work)
        await core.releaseWarm(id, because: "the test")
        await core.mutateForTest(id) {
            $0.costToDate = ["USD": 2]
            $0.costCeiling = Cost(amount: 1, currency: "USD")
        }
        let launches = launcher.launchCount
        try await core.prewarm(.init(agentID: id, why: .opened))
        try await Task.sleep(for: .milliseconds(200))
        #expect(launcher.launchCount == launches, "its prompt would be held, so nothing is warmed for it")
    }

    @Test func aFailingRuntimeIsBackedOffAndSaidOnce() async throws {
        let (locations, work) = try temporary()
        let launcher = FlakyLauncher()
        let clock = Clock()
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher, now: { clock.now })
        _ = await core.setWakeSettings(WakeSettings(keepsAwake: false, graceHours: 0, warmRuntimes: 3))
        let id = try await chat(core, work)
        await core.releaseWarm(id, because: "the test")
        launcher.fails = true

        try await core.prewarm(.init(agentID: id, why: .opened))
        await eventually("the failure is heard") { await core.prewarmFailures["cursor"] != nil }
        await eventually("and the prewarm is over") { await core.prewarming.isEmpty }
        let failedAt = await core.prewarmFailures["cursor"]
        #expect(launcher.failures == 1)

        // Past the debounce, asked again and again: nothing is started, nothing new said.
        for _ in 0..<3 {
            clock.advance(DaemonCore.prewarmDebounce + 1)
            try await core.prewarm(.init(agentID: id, why: .opened))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(launcher.failures == 1, "backed off")
        #expect(await core.prewarmFailures["cursor"] == failedAt, "remembered from the first, said once")

        // Once the back-off has passed, it is tried again.
        launcher.fails = false
        clock.advance(DaemonCore.prewarmBackoff)
        try await core.prewarm(.init(agentID: id, why: .opened))
        await eventually("it warmed") { await core.warm[id] != nil }
        #expect(await core.prewarmFailures["cursor"] == nil, "a start clears it")
    }

    @Test func anAgentWaitingToBeWokenIsExpected() async throws {
        let (locations, work) = try temporary()
        let clock = Clock()
        let core = try await core(FakeLauncher(keepsRuntimesWarm: true), locations, clock: clock)
        let lead = try await chat(core, work)
        let errand = try await chat(core, work)
        let waiting = try await chat(core, work)
        await core.mutateForTest(errand) { $0.startedByAgent = lead }
        await core.mutateForTest(waiting) {
            $0.startedByAgent = lead
            $0.eventWait = EventWait(patterns: [], from: EventPosition(0), since: clock.now)
        }
        await core.forgetPromptsForTest(errand)
        await core.forgetPromptsForTest(waiting)
        await core.machineChanged(.away(why: "locked"))
        clock.advance(WarmPool.awayDrainsAfter + 1)

        for id in [errand, waiting] {
            await core.takeFromPoolForTest(id)
            await core.keepWarmOrRelease(id)
        }
        #expect(await core.live[errand] == nil, "an agent's errand with the person away goes, as before")
        #expect(await isWarm(core, waiting), "one the app will wake is kept for its wake")
    }
}

/// The score on its own: what outranks what.
@Suite("Warm pool scoring")
struct WarmPoolScoreTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func needsAnswerOutranksAnOldFinish() {
        var asking = WarmPool.Signals()
        asking.personsConversation = true
        asking.needsAnswer = true
        var plain = WarmPool.Signals()
        plain.personsConversation = true
        plain.lastPersonPrompt = now
        let old = WarmPool.score(.init(since: now.addingTimeInterval(-15 * 60)), asking, now: now)
        let fresh = WarmPool.score(.init(since: now.addingTimeInterval(-15 * 60)), plain, now: now)
        #expect(old > fresh)
        #expect(WarmPool.score(.init(since: now.addingTimeInterval(-60)), asking, now: now)
                > WarmPool.score(.init(since: now.addingTimeInterval(-20 * 60)), plain, now: now))
    }

    @Test func zeroForErrandsParkedAndPastTheCeiling() {
        var errand = WarmPool.Signals()
        errand.personsConversation = false
        #expect(WarmPool.score(.init(since: now), errand, now: now) == 0)
        var parked = WarmPool.Signals()
        parked.personsConversation = true
        parked.parked = true
        #expect(WarmPool.score(.init(since: now), parked, now: now) == 0)
        var chat = WarmPool.Signals()
        chat.personsConversation = true
        chat.watchedActive = true
        #expect(WarmPool.score(.init(since: now.addingTimeInterval(-WarmPool.ceiling)), chat, now: now) == 0)
        // Intent on an errand is still intent.
        #expect(WarmPool.score(.init(since: now, intentAt: now), errand, now: now) > 0)
    }

    @Test func releasesKeepTheHighestWithinTheCap() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let gone = WarmPool.releases([(a, 10, now), (b, 50, now), (c, 0, now), (d, 30, now)], cap: 2)
        #expect(Set(gone) == [a, c])
        #expect(WarmPool.releases([(a, 10, now)], cap: 0) == [a])
    }

    @Test func intentOnAnotherSurfaceOutweighsBeingAwayFromTheMac() {
        var away = WarmPool.Signals()
        away.personsConversation = true
        away.personAway = true
        #expect(WarmPool.score(.init(since: now), away, now: now) == 0)
        #expect(WarmPool.score(.init(since: now, intentAt: now), away, now: now) > 0)
    }

    @Test func aPendingWakeCountsWithNobodyAbout() {
        var errand = WarmPool.Signals()
        errand.personsConversation = false
        errand.personAway = true
        #expect(WarmPool.score(.init(since: now), errand, now: now) == 0)
        errand.pendingWake = true
        #expect(WarmPool.score(.init(since: now), errand, now: now) > 0)
        errand.parked = true
        #expect(WarmPool.score(.init(since: now), errand, now: now) == 0, "parked still goes")
    }

    @Test func typicalGapWantsThreePrompts() {
        #expect(WarmPool.typicalGap([now, now.addingTimeInterval(60)]) == nil)
        #expect(WarmPool.typicalGap([now, now.addingTimeInterval(60), now.addingTimeInterval(180)]) == 120)
    }
}

extension DaemonCore {
    func isBusyForTest(_ id: UUID) -> Bool {
        turnTasks[id] != nil || sending.contains(id) || launching[id] != nil
    }

    func forgetPromptsForTest(_ id: UUID) {
        personPromptTimes.removeValue(forKey: id)
    }

    func takeFromPoolForTest(_ id: UUID) {
        warm.removeValue(forKey: id)
    }

    /// The turn end's decision is made: pooled, or let go.
    func decidedForTest(_ id: UUID) -> Bool {
        warm[id] != nil || live[id] == nil
    }

    /// Runtimes of these agents held by the pool: warm, or being started for it. Counted
    /// by runtime, not by the prewarm's place: a prewarm that is making room holds its
    /// place while the one it outranks is let go, and launches only after. Under load
    /// that letting go is slow enough to be seen, and is not a fourth runtime (#225).
    func poolRuntimesForTest(_ ids: [UUID]) -> Int {
        ids.filter { (live[$0] != nil || launching[$0] != nil) && turnTasks[$0] == nil }.count
    }

    func isWarmForTest(_ id: UUID) -> Bool {
        warm[id] != nil && live[id] != nil
    }

    /// Change an agent's record in place, for a fact a test cannot reach any other way.
    func mutateForTest(_ id: UUID, _ change: @Sendable (inout Agent) -> Void) {
        guard var agent = agents[id] else { return }
        change(&agent)
        agents[id] = agent
    }
}

extension Sequence {
    func asyncCount(_ test: (Element) async -> Bool) async -> Int {
        var count = 0
        for element in self where await test(element) { count += 1 }
        return count
    }
}

/// A fake launcher whose launches can be made to fail, for a runtime that will not start.
final class FlakyLauncher: SessionLauncher, @unchecked Sendable {
    private let fake = FakeLauncher(keepsRuntimesWarm: true)
    private let lock = NSLock()
    private var failing = false
    private var failed = 0
    var keepsRuntimesWarm: Bool { true }

    var fails: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    var failures: Int { lock.withLock { failed } }

    func launch(runtime: Runtime, path: String, cwd: URL) throws -> ACPSession {
        let fail = lock.withLock { () -> Bool in
            if failing { failed += 1 }
            return failing
        }
        if fail { throw CocoaError(.fileNoSuchFile) }
        return try fake.launch(runtime: runtime, path: path, cwd: cwd)
    }
}
