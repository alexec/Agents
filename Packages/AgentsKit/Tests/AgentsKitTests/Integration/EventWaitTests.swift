import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Agents waiting for something to happen, through the daemon (042 US1, US4).
///
/// What the log and the pattern alone cannot show: that a held call is answered when
/// its event comes, that an agent whose call has returned is started again with the
/// news once, that every way of ending a wait ends it without a wake, that a restart
/// keeps it, and that publishing wakes and is limited. Replies are checked for their
/// words, because the agent reads them.
@Suite("Event waits", .timeLimit(.minutes(1)))
struct EventWaitTests {
    /// Which agent each token speaks for, bound again before every call, as `LeaseTests` does.
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

    private func temporary() throws -> (StoreLocations, URL, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsEvents-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        let other = root.appendingPathComponent("other", isDirectory: true)
        for folder in [work, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        return (StoreLocations(root: root), Project.standardize(work), Project.standardize(other))
    }

    private func makeCore(_ locations: StoreLocations, clock: Clock,
                          hold: Duration = .seconds(5)) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(),
                              now: { clock.now })
        await core.loadFromDisk()
        await core.useForEvents(holdLimit: hold)
        return core
    }

    private func agent(_ core: DaemonCore, in folder: URL, _ title: String) async throws -> (UUID, String) {
        let id = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: folder, prompt: title))
        let token = UUID().uuidString
        callers[token] = id
        await core.bindAppToken(token, to: id)
        return (id, token)
    }

    /// A call with its token bound again first, made again if the caller's session
    /// ended in between, as `LeaseTests.calling` does.
    private func calling<T>(_ core: DaemonCore, _ token: String,
                            _ body: (String) async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                if let id = callers[token] { await core.bindAppToken(token, to: id) }
                return try await body(token)
            } catch let error as JSONRPCError
                        where error.message == LeaseWords.noConversation && callers[token] != nil && attempt < 5 {
                attempt += 1
            }
        }
    }

    private func wait(_ core: DaemonCore, _ token: String, _ events: [String], where filters: [String: String]? = nil,
                      from: EventPosition? = nil, until: Int? = nil) async throws -> String {
        try await calling(core, token) { t in
            try await core.waitForEvent(.init(token: t, events: events, where: filters, from: from, untilMinutes: until))
        }
    }

    private func refusal(_ body: () async throws -> Void) async -> JSONRPCError? {
        do { try await body(); return nil } catch let error as JSONRPCError { return error } catch { return nil }
    }

    private func draft(_ name: String, in folder: URL?, _ details: [String: String] = [:]) -> EventDraft {
        EventDraft(name: name, scope: folder.map { .project(folder: $0) } ?? .mac, sentence: name, details: details)
    }

    private func appPrompts(_ core: DaemonCore, _ id: UUID) async throws -> [String] {
        try await core.transcript(.init(agentID: id, before: nil, limit: 500)).entries.compactMap {
            if case .userMessage(let text, _, .app) = $0.kind { return text } else { return nil }
        }
    }

    /// The app prompts that are wakes from a wait, as against the app's other words
    /// (the question it asks after a turn that ended without saying how it went).
    private func wakes(_ core: DaemonCore, _ id: UUID) async throws -> [String] {
        try await appPrompts(core, id).filter {
            $0.hasPrefix("The event you were waiting for happened.") || $0.hasPrefix("Your wait for ")
        }
    }

    private func eventually(_ what: String, _ check: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: max(.seconds(20), Eventually.timeout))
        while ContinuousClock.now < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("never happened: \(what)")
    }

    private func isWaiting(_ core: DaemonCore, _ id: UUID) async -> Bool {
        await core.agents[id]?.eventWait?.isOpen == true
    }

    private func isHeld(_ core: DaemonCore, _ id: UUID) async -> Bool {
        await core.openEventWaits[id] != nil
    }

    @Test func everyAgentIsBriefedAboutWaiting() {
        for policy in ToolPolicyCatalog.builtIn {
            #expect(Briefing.lines(for: policy, managesAgents: false).contains(Briefing.events))
            #expect(Briefing.lines(for: policy, managesAgents: true).contains(Briefing.events))
        }
    }

    // MARK: US1: waiting

    @Test func aMatchInsideTheHoldAnswersTheCall() async throws {
        let (locations, work, _) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let (a, token) = try await agent(core, in: work, "Waiter")

        let call = Task { try await wait(core, token, ["custom.ping"]) }
        try await eventually("held") { await isHeld(core, a) }
        await core.raise(draft("custom.ping", in: work))
        let answer = try await call.value
        #expect(answer.hasPrefix("custom.ping happened at "))
        #expect(answer.hasSuffix("You can carry on."))
        #expect(!(await isWaiting(core, a)))
        let event = await core.eventLog.events.last { $0.name == "custom.ping" }
        #expect(event?.consequences == [.woke(agentID: a, title: "Waiter")])
    }

    /// `server.offline` and `server.online` come from the window, which holds the
    /// servers' connections: its word wakes a wait on the server it names, and no other.
    @Test func theWindowSayingAServerWentWakesAWaitOnIt() async throws {
        let (locations, work, _) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let (a, token) = try await agent(core, in: work, "Watcher")

        let call = Task { try await wait(core, token, ["server.offline"], where: ["server": "devbox"]) }
        try await eventually("held") { await isHeld(core, a) }
        let other = try JSONValue.encoding(DaemonAPI.ServerReachabilityChange(server: "buildbox", online: false))
        _ = await core.handle(method: DaemonAPI.Method.eventsServer, params: other, from: .mac)
        #expect(await isHeld(core, a))
        let params = try JSONValue.encoding(DaemonAPI.ServerReachabilityChange(server: "devbox", online: false))
        guard case .success = await core.handle(method: DaemonAPI.Method.eventsServer, params: params, from: .mac) else {
            Issue.record("the window's word was refused"); return
        }
        let answer = try await call.value
        #expect(answer.hasPrefix("server.offline happened at "))
        let event = await core.eventLog.events.last { $0.name == "server.offline" }
        #expect(event?.details["server"] == "devbox")
        #expect(event?.scope == .mac)

        let back = try JSONValue.encoding(DaemonAPI.ServerReachabilityChange(server: "devbox", online: true))
        _ = await core.handle(method: DaemonAPI.Method.eventsServer, params: back, from: .mac)
        #expect(await core.eventLog.events.last?.name == "server.online")
    }

    @Test func aPhoneCannotSayAServerWent() async throws {
        let (locations, _, _) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let params = try JSONValue.encoding(DaemonAPI.ServerReachabilityChange(server: "devbox", online: false))
        guard case .failure(let error) = await core.handle(method: DaemonAPI.Method.eventsServer, params: params,
                                                           from: .device(UUID())) else {
            Issue.record("a phone said a server went"); return
        }
        #expect(error.code == DaemonAPI.Failure.eventRefused)
        #expect(!(await core.eventLog.events.contains { $0.name.hasPrefix("server.") }))
    }

    @Test func pastTheHoldItSaysStillWaitingAndIsStartedWhenItComes() async throws {
        let (locations, work, _) = try temporary()
        let core = try await makeCore(locations, clock: Clock(), hold: .milliseconds(150))
        let (a, token) = try await agent(core, in: work, "Waiter")

        let answer = try await wait(core, token, ["custom.ping"])
        #expect(answer.hasPrefix("Still waiting for custom.ping, since "))
        #expect(answer.contains("you can end your turn"))
        #expect(await isWaiting(core, a))
        #expect(await core.eventLog.events.contains { $0.name == "agent.blocked" && $0.details["agent"] == a.uuidString })
        try await eventually("turn over, Blocked") {
            await core.agents[a]?.group(wantsEyes: false) == .blocked
        }

        await core.raise(draft("custom.ping", in: work))
        try await eventually("started with the event") {
            try await appPrompts(core, a).contains { $0.hasPrefix("The event you were waiting for happened.") }
        }
        #expect(!(await isWaiting(core, a)))
    }

    @Test func aDeadlineWakesItTimedOut() async throws {
        let clock = Clock()
        let (locations, work, _) = try temporary()
        let core = try await makeCore(locations, clock: clock, hold: .milliseconds(100))
        let (a, token) = try await agent(core, in: work, "Patient")
        _ = try await wait(core, token, ["custom.never"], until: 1)
        clock.advance(minutes: 2)
        await core.eventWaitDeadlinesPassed()
        try await eventually("told it timed out") {
            try await appPrompts(core, a).contains { $0.hasPrefix("Your wait for custom.never timed out at ") }
        }
    }

    @Test func waitingFromAnEarlierPositionCatchesWhatCameBetween() async throws {
        let (locations, work, _) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let (_, token) = try await agent(core, in: work, "Checker")
        let head = await core.eventLog.head
        await core.raise(draft("custom.build_green", in: work))
        let answer = try await wait(core, token, ["custom.build_green"], from: head)
        #expect(answer.hasPrefix("custom.build_green happened at "))
        // From now, the same event is in the past and does not count.
        let later = Task { try await wait(core, token, ["custom.build_green"]) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!later.isCancelled)
        later.cancel()
    }

    @Test func severalMatchesWakeItOnceAndItIsToldHowMany() async throws {
        let (locations, work, _) = try temporary()
        let core = try await makeCore(locations, clock: Clock(), hold: .milliseconds(100))
        let (a, token) = try await agent(core, in: work, "Waiter")
        _ = try await wait(core, token, ["custom.*"])
        await core.raiseEach([draft("custom.one", in: work), draft("custom.two", in: work), draft("custom.three", in: work)])
        try await eventually("woken once") {
            try await appPrompts(core, a).contains { $0.contains("2 more matches arrived before you resumed") }
        }
        let wakes = try await appPrompts(core, a).filter { $0.hasPrefix("The event you were waiting for happened.") }
        #expect(wakes.count == 1)
    }

    @Test func aSecondWaitReplacesTheFirst() async throws {
        let (locations, work, _) = try temporary()
        let core = try await makeCore(locations, clock: Clock(), hold: .milliseconds(100))
        let (a, token) = try await agent(core, in: work, "Fickle")
        _ = try await wait(core, token, ["custom.a"])
        let second = try await wait(core, token, ["custom.b"])
        #expect(second.hasPrefix("Replaced your earlier wait on custom.a. Still waiting for custom.b"))
        #expect(await core.agents[a]?.eventWait?.patterns == [EventPattern("custom.b")])
    }

    @Test func anotherProjectsEventsNeverMatchButTheMacsDo() async throws {
        let (locations, work, other) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let (a, token) = try await agent(core, in: work, "Here")
        let call = Task { try await wait(core, token, ["custom.ping", "mac.wake"]) }
        try await eventually("held") { await isHeld(core, a) }
        await core.raise(draft("custom.ping", in: other))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await isHeld(core, a), "another project's ping is not ours")
        await core.raise(draft("mac.wake", in: nil))
        #expect(try await call.value.hasPrefix("mac.wake happened at "))
    }

    @Test func itIsNeverWokenByNewsOfItself() async throws {
        let (locations, work, _) = try temporary()
        let core = try await makeCore(locations, clock: Clock(), hold: .milliseconds(100))
        let (a, token) = try await agent(core, in: work, "Self")
        _ = try await wait(core, token, ["agent.*"])
        await core.raiseAgentEvent("agent.finished", a, sentence: "finished.")
        try await Task.sleep(for: .milliseconds(100))
        #expect(await isWaiting(core, a))
    }

    @Test func badWaitsAreRefusedInWords() async throws {
        let (locations, work, _) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let (_, token) = try await agent(core, in: work, "Careless")
        let unknown = await refusal { _ = try await wait(core, token, ["pull_request.merge"]) }
        #expect(unknown?.code == DaemonAPI.Failure.eventRefused)
        #expect(unknown?.message.contains("Did you mean pull_request.merged?") == true)
        let filter = await refusal { _ = try await wait(core, token, ["pull_request.merged"], where: ["branch": "x"]) }
        #expect(filter?.message == "pull_request.merged carries number; \"branch\" is not one of its details.")
        for minutes in [0, 1441] {
            let deadline = await refusal { _ = try await wait(core, token, ["mac.wake"], until: minutes) }
            #expect(deadline?.message == EventWords.badDeadline())
        }
        let nothing = await refusal { _ = try await wait(core, token, []) }
        #expect(nothing?.message == EventWords.nothingNamed)
    }

    @Test func recentAndListRead() async throws {
        let (locations, work, other) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let (_, token) = try await agent(core, in: work, "Reader")
        await core.raise(draft("custom.mine", in: work))
        await core.raise(draft("custom.theirs", in: other))
        let recent = try await calling(core, token) { t in try await core.waitForEvent(.init(token: t, action: "recent")) }
        #expect(recent.contains("custom.mine"))
        #expect(!recent.contains("custom.theirs"))
        #expect(recent.contains("Head: "))
        let list = try await calling(core, token) { t in try await core.waitForEvent(.init(token: t, action: "list")) }
        #expect(list == EventCatalogue.describe())
    }

    // MARK: US1: ending a wait without a wake (FR-013)

    @Test func cancelWaitEndsItAndNothingWakesLater() async throws {
        let (locations, work, _) = try temporary()
        let core = try await makeCore(locations, clock: Clock(), hold: .milliseconds(100))
        let (a, token) = try await agent(core, in: work, "Quitter")
        _ = try await wait(core, token, ["custom.ping"])
        let reply = try await calling(core, token) { t in try await core.cancelWait(.init(token: t)) }
        #expect(reply == "Stopped waiting for custom.ping.")
        await core.raise(draft("custom.ping", in: work))
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await wakes(core, a).isEmpty)
        let none = await refusal { _ = try await calling(core, token) { t in try await core.cancelWait(.init(token: t)) } }
        #expect(none?.code == DaemonAPI.Failure.noWait)
        #expect(none?.message == EventWords.notWaiting)
    }

    @Test func thePersonCancelsFromTheMac() async throws {
        let (locations, work, _) = try temporary()
        let core = try await makeCore(locations, clock: Clock(), hold: .milliseconds(100))
        let (a, token) = try await agent(core, in: work, "Watched")
        _ = try await wait(core, token, ["custom.ping"])
        #expect(await core.waitingAgents().map(\.agentID) == [a])
        let left = try await core.cancelWaitByPerson(.init(agentID: a))
        #expect(left.isEmpty)
        #expect(!(await isWaiting(core, a)))
    }

    @Test func thePersonsPromptTakesThePlaceOfTheWaitAndTheAgentIsTold() async throws {
        let (locations, work, _) = try temporary()
        let core = try await makeCore(locations, clock: Clock(), hold: .milliseconds(100))
        let (a, token) = try await agent(core, in: work, "Interrupted")
        _ = try await wait(core, token, ["custom.ping"])
        try await eventually("turn over") { await core.agents[a]?.state == .finished }
        try await core.prompt(DaemonAPI.PromptRequest(agentID: a, text: "Do this instead."))
        #expect(!(await isWaiting(core, a)))
        // Recorded when its turn begins, which may be behind the app's own question.
        try await eventually("the person's prompt went") {
            try await core.transcript(.init(agentID: a, before: nil, limit: 500)).entries.contains {
                if case .userMessage(let text, _, .person) = $0.kind { return text == "Do this instead." }
                return false
            }
        }
        let said = try await core.transcript(.init(agentID: a, before: nil, limit: 500)).entries.compactMap {
            if case .userMessage(let text, _, _) = $0.kind { return text } else { return nil }
        }
        #expect(!said.contains { $0.contains("(Your wait for") }, "the preface is for the runtime, not the record")
        await core.raise(draft("custom.ping", in: work))
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await wakes(core, a).isEmpty)
    }

    @Test func stoppingOrArchivingEndsIt() async throws {
        let (locations, work, _) = try temporary()
        let core = try await makeCore(locations, clock: Clock(), hold: .milliseconds(100))
        let (a, first) = try await agent(core, in: work, "Stopped")
        let (b, second) = try await agent(core, in: work, "Archived")
        _ = try await wait(core, first, ["custom.ping"])
        _ = try await wait(core, second, ["custom.ping"])
        try await core.stop(a)
        try await core.archive(b)
        #expect(!(await isWaiting(core, a)))
        #expect(!(await isWaiting(core, b)))
        await core.raise(draft("custom.ping", in: work))
        try await Task.sleep(for: .milliseconds(150))
        #expect(try await wakes(core, a).isEmpty)
        #expect(try await wakes(core, b).isEmpty)
    }

    // MARK: Restarts (FR-014, SC-005)

    @Test func aWaitSurvivesTwentyRestarts() async throws {
        let clock = Clock()
        let (locations, work, _) = try temporary()
        let core = try await makeCore(locations, clock: clock, hold: .milliseconds(100))
        let (a, token) = try await agent(core, in: work, "Durable")
        _ = try await wait(core, token, ["pull_request.merged"], where: ["number": "44"])
        let head = await core.eventLog.head
        for _ in 0..<20 {
            let again = try await makeCore(locations, clock: clock)
            _ = await again.recover()
            await again.resumeEventWaitsAfterRestart()
            #expect(await again.agents[a]?.eventWait?.isOpen == true)
            #expect(await again.agents[a]?.eventWait?.patterns == [EventPattern("pull_request.merged", filters: ["number": "44"])])
            #expect(await again.isHoldingAgents, "a wait keeps the daemon up")
        }
        let last = try await makeCore(locations, clock: clock)
        _ = await last.recover()
        #expect(await last.eventLog.events.filter { $0.position > head && $0.name.hasPrefix("mac.") }.isEmpty,
                "nothing is invented for the time it was down")
    }

    // MARK: US4: publishing

    @Test func aPublishWakesAWaiterAndSaysSo() async throws {
        let (locations, work, _) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let (a, waiterToken) = try await agent(core, in: work, "Merge when green")
        let (b, publisherToken) = try await agent(core, in: work, "Nightly build")
        let call = Task { try await wait(core, waiterToken, ["custom.build_green"]) }
        try await eventually("held") { await isHeld(core, a) }
        let reply = try await calling(core, publisherToken) { t in
            try await core.publishEvent(.init(token: t, name: "custom.build_green", message: "All green",
                                             details: ["branch": "main"]))
        }
        #expect(reply.hasPrefix("Published custom.build_green (position "))
        #expect(reply.contains("Woke \u{201C}Merge when green\u{201D}."))
        let answer = try await call.value
        #expect(answer.contains("Message: All green"))
        let event = await core.eventLog.events.last { $0.name == "custom.build_green" }
        #expect(event?.publisher == EventPublisher(agentID: b, title: "Nightly build"))
        #expect(event?.details == ["branch": "main"])
    }

    @Test func onlyCustomNamesArePublished() async throws {
        let (locations, work, _) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let (_, token) = try await agent(core, in: work, "Impostor")
        let refused = await refusal {
            _ = try await calling(core, token) { t in try await core.publishEvent(.init(token: t, name: "mac.wake")) }
        }
        #expect(refused?.code == DaemonAPI.Failure.eventRefused)
        #expect(refused?.message == EventWords.publishOutsideCustom("mac.wake"))
        let long = await refusal {
            _ = try await calling(core, token) { t in
                try await core.publishEvent(.init(token: t, name: "custom.x", message: String(repeating: "m", count: 501)))
            }
        }
        #expect(long?.message.contains("500") == true)
    }

    @Test func theThirtyFirstPublishInAnHourIsRefused() async throws {
        let (locations, work, _) = try temporary()
        let core = try await makeCore(locations, clock: Clock())
        let (_, token) = try await agent(core, in: work, "Chatty")
        for i in 0..<DaemonCore.publishesPerHour {
            _ = try await calling(core, token) { t in try await core.publishEvent(.init(token: t, name: "custom.n\(i)")) }
        }
        let refused = await refusal {
            _ = try await calling(core, token) { t in try await core.publishEvent(.init(token: t, name: "custom.more")) }
        }
        #expect(refused?.message.hasPrefix("You've published 30 events in the last hour") == true)
    }
}

extension DaemonCore {
    /// Several events in one turn of the actor, so the second and third find the first's
    /// wake still queued.
    func raiseEach(_ drafts: [EventDraft]) {
        for draft in drafts { raise(draft) }
    }
}
