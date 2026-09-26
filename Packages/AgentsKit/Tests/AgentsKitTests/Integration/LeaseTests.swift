import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Agents taking turns with the Mac's shared things (036), through the daemon.
///
/// What this suite holds is what the book alone cannot: that a waiting call is answered
/// when the lease comes, that an agent whose call has returned is started again with
/// the news, that stopping and archiving let go, that a restart keeps everything, and
/// that the person can end a lease or empty a place in line but never take one. Every
/// reply is checked for its words, because the agent reads them and repeats them.
@Suite("Resource leases", .timeLimit(.minutes(1)))
struct LeaseTests {
    /// Which agent each token speaks for, bound again before every call: a fake agent's
    /// turn ends when it likes, and its token goes with it. As `HelperAgentTests` does.
    private final class Callers: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String: UUID] = [:]
        subscript(token: String) -> UUID? {
            get { lock.withLock { ids[token] } }
            set { lock.withLock { ids[token] = newValue } }
        }
    }
    private let callers = Callers()

    /// A clock a test can move. Whole seconds, so what the store keeps is what was set.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { date } }
        func advance(minutes: Double) { lock.withLock { date = date.addingTimeInterval(minutes * 60) } }
    }

    private let simulator = FoundResource(
        name: ResourceName("simulator:aaaa-1111")!, kind: .simulator,
        displayName: "iPhone 17 Pro · iOS 26.0", aliases: ["AAAA-1111", "iPhone 17 Pro · iOS 26.0"])

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsLeases-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    private func makeCore(_ locations: StoreLocations, clock: Clock,
                          waitLimit: Duration = .seconds(5)) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(),
                              now: { clock.now })
        await core.loadFromDisk()
        await core.useForLeases(catalog: FixedCatalog([.screen, simulator]), waitLimit: waitLimit)
        return core
    }

    /// An agent the person started, and a token that speaks for it.
    private func agent(_ core: DaemonCore, in folder: URL, _ title: String) async throws -> (UUID, String) {
        let id = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: folder, prompt: title))
        let token = UUID().uuidString
        callers[token] = id
        await core.bindAppToken(token, to: id)
        return (id, token)
    }

    private func bound(_ core: DaemonCore, _ token: String) async -> String {
        if let id = callers[token] { await core.bindAppToken(token, to: id) }
        return token
    }

    /// A call made with the token bound again first, and made again if the caller's
    /// session ended in the moment between the two — which a fake agent's quick turn
    /// can do under load. As `HelperAgentTests.calling` does. Only for a token that
    /// speaks for an agent; one that never did still sees its refusal.
    private func calling<T>(_ core: DaemonCore, _ token: String,
                            _ body: (String) async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body(await bound(core, token))
            } catch let error as JSONRPCError
                        where error.message == LeaseWords.noConversation
                        && callers[token] != nil && attempt < 5 {
                attempt += 1
            }
        }
    }

    private func lease(_ core: DaemonCore, _ token: String, _ name: String = "screen",
                       minutes: Int? = nil, wait: Bool? = nil) async throws -> String {
        try await calling(core, token) { t in
            try await core.lease(.init(token: t, name: name, minutes: minutes, wait: wait))
        }
    }

    private func release(_ core: DaemonCore, _ token: String, _ name: String = "screen") async throws -> String {
        try await calling(core, token) { t in try await core.releaseLease(.init(token: t, name: name)) }
    }

    private func list(_ core: DaemonCore, _ token: String) async throws -> String {
        try await calling(core, token) { t in try await core.listLeases(.init(token: t)) }
    }

    private func refusal(_ body: () async throws -> Void) async -> JSONRPCError? {
        do { try await body(); return nil } catch let error as JSONRPCError { return error } catch { return nil }
    }

    private func transcript(_ core: DaemonCore, _ id: UUID) async throws -> [TranscriptEntry] {
        try await core.transcript(.init(agentID: id, before: nil, limit: 500)).entries
    }

    private func notes(_ core: DaemonCore, _ id: UUID) async throws -> [String] {
        try await transcript(core, id).compactMap {
            if case .runtimeNote(let text) = $0.kind { return text } else { return nil }
        }
    }

    private func appPrompts(_ core: DaemonCore, _ id: UUID) async throws -> [String] {
        try await transcript(core, id).compactMap {
            if case .userMessage(let text, _, .app) = $0.kind { return text } else { return nil }
        }
    }

    /// Until something is true, or twenty seconds pass. Long for a quiet machine, and
    /// needed on a busy one: under the whole suite, starting a woken agent's fake
    /// runtime has taken longer than eight.
    private func eventually(_ what: String, _ check: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("never happened: \(what)")
    }

    private func holder(_ core: DaemonCore, _ name: ResourceName = .screen) async -> UUID? {
        await core.leaseBook.entry(name)?.lease?.holder
    }

    private func line(_ core: DaemonCore, _ name: ResourceName = .screen) async -> [UUID] {
        await core.leaseBook.entry(name)?.line.map(\.agentID) ?? []
    }

    // MARK: US1: take, extend, list, release

    @Test func anAgentTakesExtendsListsAndReleases() async throws {
        let clock = Clock()
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: clock)
        let (a, token) = try await agent(core, in: work, "Walk the phone")

        let taken = try await lease(core, token, " Screen ", minutes: 20)
        #expect(taken == "You hold Screen, mouse and keyboard until \(LeaseWords.clock(clock.now.addingTimeInterval(1200))) "
                + "(20 minutes). Release it with release_resource when you are done.")
        #expect(await holder(core) == a)

        clock.advance(minutes: 5)
        let extended = try await lease(core, token, "screen", minutes: 30)
        #expect(extended == "You still hold Screen, mouse and keyboard, now until "
                + "\(LeaseWords.clock(clock.now.addingTimeInterval(1800))).")

        let listed = try await list(core, token)
        #expect(listed.hasPrefix("Yours:\n- Holding Screen, mouse and keyboard (screen) until "))
        #expect(listed.contains("On this Mac:"))
        #expect(listed.contains("- simulator:aaaa-1111 \u{2014} iPhone 17 Pro · iOS 26.0: free."))

        let released = try await release(core, token)
        #expect(released == "Released Screen, mouse and keyboard.")
        #expect(await core.leaseBook.isEmpty)

        let said = try await notes(core, a)
        #expect(said.contains { $0.hasPrefix("Leased Screen, mouse and keyboard until ") })
        #expect(said.contains { $0.hasPrefix("Extended the lease on Screen, mouse and keyboard to ") })
        #expect(said.contains("Released Screen, mouse and keyboard."))
    }

    @Test func tooLongIsCutAndSaysSo() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let (_, token) = try await agent(core, in: work, "Long")
        let reply = try await lease(core, token, minutes: 600)
        #expect(reply.contains("(240 minutes)"))
        #expect(reply.hasSuffix(LeaseWords.capped))
    }

    @Test func aSimulatorByItsUDIDIsTheSameResource() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let (a, first) = try await agent(core, in: work, "One")
        let (_, second) = try await agent(core, in: work, "Two")
        _ = try await lease(core, first, "aaaa-1111")
        let reply = try await lease(core, second, "simulator:AAAA-1111", wait: false)
        #expect(reply.hasPrefix("iPhone 17 Pro · iOS 26.0 is held by \u{201C}One\u{201D}"))
        #expect(await holder(core, simulator.name) == a)
    }

    @Test func aNameOfItsOwnWorksAndGoesWhenFree() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let (_, token) = try await agent(core, in: work, "Server")
        _ = try await lease(core, token, "Port 8080")
        let snapshot = await core.leaseSnapshot()
        #expect(snapshot.resources.last?.kind == .named)
        #expect(snapshot.resources.last?.displayName == "Port 8080")
        _ = try await release(core, token, "port 8080")
        #expect(await core.leaseSnapshot().resources.allSatisfy { $0.kind != .named })
    }

    @Test func aTokenThatMeansNothingLeasesNothing() async throws {
        let (locations, _) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let error = await refusal { _ = try await core.lease(.init(token: "nobody", name: "screen")) }
        #expect(error?.message == LeaseWords.noConversation)
    }

    @Test func anEmptyNameLeasesNothing() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let (_, token) = try await agent(core, in: work, "Blank")
        let error = await refusal { _ = try await lease(core, token, "   ") }
        #expect(error?.message == LeaseWords.emptyName)
    }

    @Test func everyAgentIsOfferedTheToolsAndBriefed() async throws {
        for policy in ToolPolicyCatalog.builtIn {
            #expect(Briefing.lines(for: policy, managesAgents: false).contains(Briefing.leases))
            #expect(Briefing.lines(for: policy, managesAgents: true).contains(Briefing.leases))
        }
    }

    // MARK: US2: waiting and being let through

    @Test func aWaitingCallIsAnsweredWhenTheLeaseComes() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let (_, first) = try await agent(core, in: work, "First")
        let (b, second) = try await agent(core, in: work, "Second")
        _ = try await lease(core, first)

        let waiting = Task { try await lease(core, second, minutes: 10) }
        try await eventually("b in line") { await line(core) == [b] }
        #expect(await core.buildLeaseSnapshot().resources.first?.line.first?.isCallOpen == true)
        let released = try await release(core, first)
        #expect(released == "Released Screen, mouse and keyboard. It has gone to \u{201C}Second\u{201D}.")

        let answer = try await waiting.value
        #expect(answer.hasPrefix("Screen, mouse and keyboard is yours now, until "))
        #expect(answer.contains("(10 minutes). You waited "))
        #expect(await holder(core) == b)
        #expect(try await appPrompts(core, b).allSatisfy { !$0.contains("is yours now") },
                "answered in its call, not started again")
    }

    @Test func aCallThatWaitsTooLongKeepsItsPlaceAndTheAgentIsStartedWhenItComes() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: Clock(), waitLimit: .milliseconds(200))
        let (_, first) = try await agent(core, in: work, "First")
        let (b, second) = try await agent(core, in: work, "Second")
        _ = try await lease(core, first)

        let answer = try await lease(core, second)
        #expect(answer.hasPrefix("Screen, mouse and keyboard is held by \u{201C}First\u{201D} until "))
        #expect(answer.hasSuffix("You are 1st in line and keep your place. Call lease_resource again to go on "
                                 + "waiting, or end your turn \u{2014} you will be started again when it is yours."))
        #expect(await line(core) == [b])

        _ = try await release(core, first)
        #expect(await holder(core) == b)
        try await eventually("b started with the news") {
            try await appPrompts(core, b).contains { $0.hasPrefix("Screen, mouse and keyboard is yours now. You hold it until ") }
        }
    }

    @Test func theLineIsServedInOrder() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: Clock(), waitLimit: .milliseconds(100))
        let (_, first) = try await agent(core, in: work, "First")
        let (b, second) = try await agent(core, in: work, "Second")
        let (c, third) = try await agent(core, in: work, "Third")
        _ = try await lease(core, first)
        _ = try await lease(core, second)
        let reply = try await lease(core, third)
        #expect(reply.contains("You are 2nd in line"))
        _ = try await release(core, first)
        #expect(await holder(core) == b)
        #expect(await line(core) == [c])
    }

    @Test func notWaitingIsToldAtOnceAndJoinsNoLine() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let (_, first) = try await agent(core, in: work, "First")
        let (_, second) = try await agent(core, in: work, "Second")
        _ = try await lease(core, first)
        let reply = try await lease(core, second, wait: false)
        #expect(reply.hasPrefix("Screen, mouse and keyboard is held by \u{201C}First\u{201D} until "))
        #expect(reply.hasSuffix(". You are not in line."))
        #expect(await line(core).isEmpty)
    }

    @Test func aWaiterReleasingLeavesTheLine() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: Clock(), waitLimit: .milliseconds(100))
        let (_, first) = try await agent(core, in: work, "First")
        let (_, second) = try await agent(core, in: work, "Second")
        _ = try await lease(core, first)
        _ = try await lease(core, second)
        #expect(try await release(core, second) == "You left the line for Screen, mouse and keyboard.")
        #expect(await line(core).isEmpty)
        #expect(try await release(core, second)
                == "You neither hold nor are waiting for Screen, mouse and keyboard; nothing changed.")
    }

    @Test func manyAskingAtOnceGiveOneHolder() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: Clock(), waitLimit: .milliseconds(300))
        var tokens: [String] = []
        for n in 0..<20 { tokens.append(try await agent(core, in: work, "Agent \(n)").1) }
        await withTaskGroup(of: Void.self) { group in
            for token in tokens {
                group.addTask {
                    do { _ = try await lease(core, token) } catch { Issue.record("\(error)") }
                }
            }
        }
        #expect(await holder(core) != nil)
        #expect(await line(core).count == 19)
    }

    @Test func aLeaseThatReachesAnAgentThatCannotRunIsPassedOn() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: Clock(), waitLimit: .milliseconds(100))
        let (_, first) = try await agent(core, in: work, "First")
        let (b, second) = try await agent(core, in: work, "Second")
        let (c, third) = try await agent(core, in: work, "Third")
        _ = try await lease(core, first)
        _ = try await lease(core, second)
        _ = try await lease(core, third)
        _ = await core.setLimits(.init(daily: .some(Cost(amount: 0, currency: "USD"))))

        // The day's limit holds every agent, so it passes b, then c, and ends free.
        _ = try await release(core, first)
        try await eventually("passed on past b and c") { await core.leaseBook.entry(.screen) == nil }
        let said = "Screen, mouse and keyboard came to this agent but it could not be started "
            + "(the day's spending limit has been reached), so it was passed on."
        #expect(try await notes(core, b).contains(said))
        #expect(try await notes(core, c).contains(said))
        #expect(try await appPrompts(core, b).allSatisfy { !$0.contains("is yours now") },
                "no news sent for a lease it lost")
        #expect(await core.agent(b)?.queuedPrompts.allSatisfy { !$0.text.contains("is yours now") } == true,
                "and none left queued")
    }

    // MARK: US5: leases do not outlive their use

    @Test func anExpiredLeaseIsHandedOnAndItsHolderToldAtItsNextCall() async throws {
        let clock = Clock()
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: clock, waitLimit: .milliseconds(100))
        let (a, first) = try await agent(core, in: work, "First")
        let (b, second) = try await agent(core, in: work, "Second")
        _ = try await lease(core, first, minutes: 10)
        _ = try await lease(core, second)

        clock.advance(minutes: 6)
        await core.lapseLeases()
        #expect(await core.buildLeaseSnapshot().resources.first?.endingSoon == true)
        clock.advance(minutes: 5)
        await core.lapseLeases()
        #expect(await holder(core) == b)
        #expect(try await notes(core, a).contains { $0.hasPrefix("The lease on Screen, mouse and keyboard ran out at ") })

        let told = try await list(core, first)
        #expect(told.hasPrefix("Your lease on Screen, mouse and keyboard ends at "))
        #expect(told.contains("You no longer hold Screen, mouse and keyboard: your lease ran out at "))
    }

    @Test func theEndOfATurnKeepsTheLease() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let (a, token) = try await agent(core, in: work, "Keeper")
        _ = try await lease(core, token)
        try await eventually("its turn is over") {
            await core.agent(a).map { !$0.state.hasTurnInFlight } ?? false
        }
        #expect(await holder(core) == a)
    }

    @Test func stoppingLetsGoAndAnswersItsOpenCall() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let (a, first) = try await agent(core, in: work, "First")
        let (b, second) = try await agent(core, in: work, "Second")
        let (c, third) = try await agent(core, in: work, "Third")
        _ = try await lease(core, first)
        _ = try await lease(core, second, "simulator:aaaa-1111")

        let waiting = Task { try await lease(core, third, "simulator:aaaa-1111") }
        try await eventually("c in line") { await line(core, simulator.name) == [c] }
        try await core.stop(c)
        let error = await refusal { _ = try await waiting.value }
        #expect(error?.message == "You were stopped, so you left the line for iPhone 17 Pro · iOS 26.0.")

        try await core.stop(a)
        #expect(await holder(core) == nil)
        #expect(try await notes(core, a).contains("Let go of Screen, mouse and keyboard when it was stopped."))
        #expect(await holder(core, simulator.name) == b)
    }

    @Test func archivingLetsGoAndSaysSo() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let (a, token) = try await agent(core, in: work, "Gone soon")
        _ = try await lease(core, token)
        try await core.archive(a)
        #expect(await holder(core) == nil)
        #expect(try await notes(core, a).contains("Let go of Screen, mouse and keyboard when it was archived."))
    }

    @Test func aRestartKeepsEveryLeaseAndLine() async throws {
        let clock = Clock()
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: clock, waitLimit: .milliseconds(100))
        let (a, first) = try await agent(core, in: work, "First")
        let (b, second) = try await agent(core, in: work, "Second")
        _ = try await lease(core, first, minutes: 30)
        _ = try await lease(core, second)
        let expiry = await core.leaseBook.entry(.screen)?.lease?.expiresAt

        let again = try await makeCore(locations, clock: clock)
        _ = await again.recover()
        #expect(await again.leaseBook.entry(.screen)?.lease?.holder == a)
        #expect(await again.leaseBook.entry(.screen)?.lease?.expiresAt == expiry)
        #expect(await again.leaseBook.entry(.screen)?.line.map(\.agentID) == [b])
        #expect(await again.leaseBook.entry(.screen)?.line.allSatisfy { !$0.isCallOpen } == true)
        #expect(await again.isHoldingAgents, "a line keeps the daemon up")
    }

    @Test(.flakyUnderLoad) func aLeaseThatRanOutWhileTheDaemonWasDownIsHandedOnAsItComesBack() async throws {
        let clock = Clock()
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: clock, waitLimit: .milliseconds(100))
        let (_, first) = try await agent(core, in: work, "First")
        let (b, second) = try await agent(core, in: work, "Second")
        _ = try await lease(core, first, minutes: 10)
        _ = try await lease(core, second)

        clock.advance(minutes: 11)
        let again = try await makeCore(locations, clock: clock)
        _ = await again.recover()
        #expect(await again.leaseBook.entry(.screen)?.lease?.holder == b)
        try await eventually("b started with the news") {
            try await appPrompts(again, b).contains { $0.hasPrefix("Screen, mouse and keyboard is yours now.") }
        }
    }

    // MARK: US4: the person takes a lease back

    @Test func thePersonEndsALeaseAndTheNextInLineGetsIt() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: Clock(), waitLimit: .milliseconds(100))
        let (a, first) = try await agent(core, in: work, "First")
        let (b, second) = try await agent(core, in: work, "Second")
        _ = try await lease(core, first)
        _ = try await lease(core, second)
        _ = try await core.endLease(.init(name: "Screen"))
        #expect(await holder(core) == b)
        // Not interrupted: nothing about the lease is sent to it or queued for it. It
        // hears at its next lease call, below.
        #expect(try await appPrompts(core, a).allSatisfy { !$0.contains("Screen") })
        #expect(await core.agent(a)?.queuedPrompts.allSatisfy { !$0.text.contains("Screen") } == true)
        #expect(try await notes(core, a).contains("You ended this agent's lease on Screen, mouse and keyboard."))
        let told = try await list(core, first)
        #expect(told.hasPrefix("You no longer hold Screen, mouse and keyboard: the person ended your lease at "))
    }

    @Test func thePersonTakesOneAgentOutOfALine() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: Clock(), waitLimit: .milliseconds(100))
        let (a, first) = try await agent(core, in: work, "First")
        let (b, second) = try await agent(core, in: work, "Second")
        let (c, third) = try await agent(core, in: work, "Third")
        _ = try await lease(core, first)
        _ = try await lease(core, second)
        _ = try await lease(core, third)
        _ = try await core.removeWaiter(.init(name: "screen", agentID: b.uuidString))
        #expect(await line(core) == [c])
        #expect(await holder(core) == a)
    }

    @Test func endingAFreeResourceIsRefused() async throws {
        let (locations, _) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let error = await refusal { _ = try await core.endLease(.init(name: "screen")) }
        #expect(error?.code == DaemonAPI.Failure.leaseRefused)
    }

    @Test func thereIsNoWayForThePersonToTakeOne() async throws {
        let (locations, _) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let answer = await core.handle(method: "leases/take", params: ["name": "screen"])
        guard case .failure(let error) = answer else {
            Issue.record("leases/take answered: \(answer)"); return
        }
        #expect(error.code == JSONRPCError.methodNotFound)
        #expect(await core.leaseBook.isEmpty)
    }

    // MARK: US3: what the windows are told

    @Test func theSnapshotShowsFoundResourcesHoldersAndLines() async throws {
        let (locations, work) = try temporary()
        let core = try await makeCore(locations, clock: Clock(), waitLimit: .milliseconds(100))
        let (a, first) = try await agent(core, in: work, "First")
        let (b, second) = try await agent(core, in: work, "Second")
        _ = try await lease(core, first)
        _ = try await lease(core, second)
        let snapshot = await core.leaseSnapshot()
        #expect(snapshot.resources.map(\.kind) == [.screen, .simulator])
        #expect(snapshot.resources[0].lease?.holder == a)
        #expect(snapshot.resources[0].line.map(\.agentID) == [b])
        #expect(snapshot.resources[0].line.first?.isCallOpen == false)
        #expect(snapshot.resources[1].lease == nil)
    }
}
