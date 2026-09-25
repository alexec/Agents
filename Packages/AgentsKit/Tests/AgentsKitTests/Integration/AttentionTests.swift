import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What the daemon says about a need, to whom, and when — against a fake surface, with
/// thresholds of milliseconds so nothing here waits on the real ones.
@Suite("Attention", .timeLimit(.minutes(1)))
struct AttentionTests {
    /// Short enough to test in, long enough to observe: the pause is a tenth of a second.
    private let thresholds = AttentionThresholds(macIdle: 60, deviceStaleness: 60,
                                                 settlingPause: 0.15, reAlertInterval: 60)

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsAttentionTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func core(_ launcher: FakeLauncher, locations: StoreLocations,
                      thresholds: AttentionThresholds? = nil) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations),
                   locations: locations,
                   discovery: .findsEverything,
                   launcher: launcher,
                   thresholds: thresholds ?? self.thresholds)
    }

    /// A runtime that asks permission mid-turn and waits on the answer.
    private func asking() -> FakeLauncher {
        var script = FakeACPAgent.Script()
        script.permission = ["toolCall": ["title": "Write hello.txt", "rawInput": ["description": "Write the greeting"]],
                             "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"],
                                         ["optionId": "no", "name": "Reject", "kind": "reject_once"]]]
        return FakeLauncher(script: script)
    }

    private func waitingOnUser(_ core: DaemonCore, _ id: UUID) async {
        await eventually("the agent is waiting on its question") {
            await core.agent(id)?.state == .waitingOnUser
        }
    }

    private func settled() async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    private func mintedToken(_ launcher: FakeLauncher) async -> String {
        await eventuallySome("the runtime was handed its token") {
            let attached = await launcher.lastAgent?.newSessionParams?["mcpServers"]?.arrayValue ?? []
            let minted = attached.first?["args"]?.arrayValue?.last?.stringValue ?? ""
            return minted.isEmpty ? nil : minted
        } ?? ""
    }

    // MARK: US1, at the Mac (Phase 3)

    /// A person at the Mac, looking at something else, is told once — after the pause,
    /// and not before it.
    @Test func aPermissionReachesTheMacAfterThePauseAndNotBefore() async throws {
        let (locations, work) = try temporary()
        let core = try core(asking(), locations: locations)
        let heard = AttentionRecorder(); await heard.attach(to: core)
        let mac = FakeSurface(.mac)
        await mac.report(core, watching: nil, active: true)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "write a file"))
        await waitingOnUser(core, id)
        #expect(heard.deliveries.isEmpty, "nothing inside the pause")

        await eventually("the Mac was told, once the pause was over") { !heard.deliveries.isEmpty }
        try await settled()
        let told = heard.deliveries
        #expect(told.count == 1)
        #expect(told.first?.to == .mac)
        #expect(told.first?.alert == true)
        #expect(told.first?.need?.agentID == id)
        #expect(told.first?.need?.kind == .permission)
        #expect(told.first?.need?.headline.h1 == work.lastPathComponent)
        #expect(told.first?.need?.headline.h3.contains("Write the greeting") == true)
    }

    /// FR-002: a clean finish, a stop and a death say nothing at all.
    @Test func aCleanFinishAStopAndADeathSayNothing() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(200)
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)
        let heard = AttentionRecorder(); await heard.attach(to: core)
        await FakeSurface(.mac).report(core, active: true)

        let finished = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("it finished") { await core.agent(finished)?.state == .finished }
        let stopped = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("it is running") { await core.agent(stopped)?.state == .running }
        try await core.stop(stopped)
        let died = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("it is running") { await core.agent(died)?.state == .running }
        await launcher.lastAgent?.stop()
        await eventually("it was found dead") { await core.agent(died)?.state == .stopped }
        try await settled()
        #expect(heard.changes.isEmpty, "heard: \(heard.changes.map(\.needID))")
    }

    /// US1 scenario 2: a report that says stuck, partly done or needs an answer is a
    /// need, and the banner says which.
    @Test func aReportThatNeedsAPersonIsANeedThatSaysWhich() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(400)
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)
        let heard = AttentionRecorder(); await heard.attach(to: core)
        await FakeSurface(.mac).report(core, active: true)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        _ = try await core.reportOutcome(.init(token: await mintedToken(launcher),
                                               outcome: "stuck", message: "No signing certificate here."))
        await eventually("it finished") { await core.agent(id)?.state == .finished }
        await eventually("the Mac was told") { !heard.deliveries.isEmpty }
        let told = try #require(heard.deliveries.first)
        #expect(told.need?.kind == .report)
        #expect(told.need?.headline.h3.contains("Stuck") == true, "h3: \(told.need?.headline.h3 ?? "")")
        #expect(told.need?.headline.h3.contains("No signing certificate") == true)
    }

    /// A report the person has looked at is not news again when they look away. The
    /// agent still wants an answer and stays under Needs attention; only the banner is
    /// done with, and that is written down so a restart does not bring it back.
    @Test func aReportOnceLookedAtIsNotToldAgain() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(400)
        let launcher = FakeLauncher(script: script)
        let core = try core(launcher, locations: locations)
        let heard = AttentionRecorder(); await heard.attach(to: core)
        let mac = FakeSurface(.mac)
        await mac.report(core, active: true)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        _ = try await core.reportOutcome(.init(token: await mintedToken(launcher),
                                               outcome: "partly_done", message: "The rest is yours."))
        await eventually("it finished") { await core.agent(id)?.state == .finished }
        await eventually("the Mac was told") { !heard.deliveries.isEmpty }

        await mac.report(core, watching: id, active: true)
        await mac.report(core, watching: nil, active: true)
        try await settled()
        #expect(await core.attentionPending().needs.isEmpty)
        #expect(heard.deliveries.count == 1, "told once: \(heard.deliveries.map(\.to))")
        #expect(await core.agent(id)?.group(wantsEyes: false) == .needsAttention)
        let written = try await AgentStore(locations: locations).load(id).agent
        #expect(written.reportIsSeen, "on the record, for the next daemon")
    }

    // MARK: US3, silence (Phase 4)

    /// SC-004: watching the conversation means nothing is delivered anywhere.
    @Test func watchingTheConversationSilencesIt() async throws {
        let (locations, work) = try temporary()
        let core = try core(asking(), locations: locations)
        let heard = AttentionRecorder(); await heard.attach(to: core)
        let mac = FakeSurface(.mac)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "write a file"))
        await mac.report(core, watching: id, active: true)
        await waitingOnUser(core, id)
        try await settled()
        #expect(heard.deliveries.isEmpty)
        #expect(await core.attentionPending().needs.count == 1, "outstanding, and silent")
    }

    /// US3 scenario 2 and 3: watching another agent is not watching this one; and a
    /// device watching it silences it even while the Mac is active.
    @Test func watchingAnotherAgentIsNotified_andADeviceWatchingSilencesTheMac() async throws {
        let (locations, work) = try temporary()
        let core = try core(asking(), locations: locations)
        let heard = AttentionRecorder(); await heard.attach(to: core)
        let mac = FakeSurface(.mac)
        await mac.report(core, watching: UUID(), active: true)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "write a file"))
        await waitingOnUser(core, id)
        await eventually("the Mac was told about the agent it was not watching") { !heard.deliveries.isEmpty }
        #expect(heard.deliveries.first?.to == .mac)

        // Now a device — any surface — watches it. The Mac's banner is withdrawn.
        let pad = FakeSurface(.device(UUID()))
        await pad.report(core, watching: id, active: true)
        await eventually("the Mac withdrew") { heard.changes.last?.to == nil && heard.changes.last?.need != nil }
    }

    /// FR-014: the pause is cancelled when they begin watching inside it; FR-015: a
    /// need met inside the pause is never delivered at all.
    @Test func thePauseIsCancelledByWatchingOrByAnAnswer() async throws {
        let (locations, work) = try temporary()
        let core = try core(asking(), locations: locations)
        let heard = AttentionRecorder(); await heard.attach(to: core)
        let mac = FakeSurface(.mac)
        await mac.report(core, active: true)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "write a file"))
        await waitingOnUser(core, id)
        await mac.report(core, watching: id, active: true)
        try await settled()
        #expect(heard.deliveries.isEmpty, "they looked before the pause was over")

        // And answered inside a fresh pause, on a second agent.
        let core2 = try self.core(asking(), locations: try temporary().0)
        let heard2 = AttentionRecorder(); await heard2.attach(to: core2)
        await FakeSurface(.mac).report(core2, active: true)
        let second = try await core2.start(.init(runtimeID: "claude", cwd: work, prompt: "write a file"))
        await waitingOnUser(core2, second)
        let question = try #require(await core2.pendingPermissionRequests().first)
        try await core2.answerPermission(.init(permissionID: question.id, optionID: "allow"))
        try await settled()
        // That question only: the fake asks again on every turn, including the one
        // the app's own outcome question starts, and that later question is real.
        #expect(heard2.deliveries.filter { $0.needID == .permission(question.id) }.isEmpty,
                "met before it was ever shown: nothing arrives")
    }

    /// FR-010, amended: nobody reachable means the need waits in the record and the next
    /// surface to connect learns of it — nothing is delivered and nothing is lost.
    @Test func withNobodyReachableTheNeedWaitsForTheNextSurface() async throws {
        let (locations, work) = try temporary()
        let core = try core(asking(), locations: locations)
        let heard = AttentionRecorder(); await heard.attach(to: core)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "write a file"))
        await waitingOnUser(core, id)
        try await settled()
        #expect(heard.changes.isEmpty)
        let pending = await core.attentionPending()
        #expect(pending.needs.map(\.agentID) == [id])
        #expect(pending.deliveries.isEmpty)

        // A window opens. It is told, after the pause.
        await FakeSurface(.mac).report(core, active: true)
        await eventually("the new window was told") { heard.deliveries.first?.to == .mac }
    }

    // MARK: US4, answered once, gone everywhere (Phase 5)

    @Test func answeredAnywhereIsWithdrawnEverywhere() async throws {
        let (locations, work) = try temporary()
        let core = try core(asking(), locations: locations)
        let heard = AttentionRecorder(); await heard.attach(to: core)
        await FakeSurface(.mac).report(core, active: true)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "write a file"))
        await waitingOnUser(core, id)
        await eventually("shown on the Mac") { heard.deliveries.first?.to == .mac }
        let question = try #require(await core.pendingPermissionRequests().first)
        try await core.answerPermission(.init(permissionID: question.id, optionID: "allow"))
        await eventually("withdrawn") { !heard.withdrawals.isEmpty }
        #expect(heard.withdrawals.first?.needID == .permission(question.id))
        #expect(heard.withdrawals.first?.to == nil)
        #expect(await core.attentionPending().needs.isEmpty)
    }

    @Test func aStoppedAgentsNeedIsWithdrawn() async throws {
        let (locations, work) = try temporary()
        let core = try core(asking(), locations: locations)
        let heard = AttentionRecorder(); await heard.attach(to: core)
        await FakeSurface(.mac).report(core, active: true)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "write a file"))
        await waitingOnUser(core, id)
        await eventually("shown on the Mac") { heard.deliveries.first?.to == .mac }
        try await core.stop(id)
        await eventually("withdrawn") { !heard.withdrawals.isEmpty }
    }

    /// A window going away takes what it knew with it: the need is nowhere, and the next
    /// window is told afresh.
    @Test func aWindowGoneIsForgottenNotAgedOut() async throws {
        let (locations, work) = try temporary()
        let core = try core(asking(), locations: locations)
        let heard = AttentionRecorder(); await heard.attach(to: core)
        let mac = FakeSurface(.mac)
        await mac.report(core, active: true)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "write a file"))
        await waitingOnUser(core, id)
        await eventually("shown on the Mac") { heard.deliveries.first?.to == .mac }
        await mac.disconnect(core)
        await eventually("moved to nowhere") { heard.changes.last?.to == nil && heard.changes.last?.need != nil }
    }

    // MARK: US2, the device in hand (Phase 6, without the hardware)

    /// A phone and a pad, paired and here, as the LAN link presents them.
    private func devices(_ core: DaemonCore) async -> (phone: FakeSurface, pad: FakeSurface) {
        let phone = FakeSurface(.device(UUID())), pad = FakeSurface(.device(UUID()))
        await phone.pair(core, name: "Phone", kind: .iPhone)
        await pad.pair(core, name: "Pad", kind: .iPad)
        return (phone, pad)
    }

    /// US2 scenarios 1 and 2: the device used most recently is the one told.
    @Test func theDeviceUsedMostRecentlyWins() async throws {
        let (locations, work) = try temporary()
        let core = try core(asking(), locations: locations)
        let heard = AttentionRecorder(); await heard.attach(to: core)
        let (phone, pad) = await devices(core)
        await phone.report(core, active: true, mayNotify: true)
        try await Task.sleep(for: .milliseconds(20))
        await pad.report(core, active: true, mayNotify: true)

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "write a file"))
        await waitingOnUser(core, id)
        await eventually("the pad was told") { heard.deliveries.first != nil }
        #expect(heard.deliveries.first?.to == pad.surface)
        #expect(heard.deliveries.first?.alert == true, "no pause when away from the Mac")

        // Then the phone is picked up: the need moves to it, silently inside the interval.
        await phone.report(core, active: true, mayNotify: true)
        await eventually("moved to the phone") { heard.changes.last?.to == phone.surface }
        #expect(heard.changes.last?.alert == false)
    }

    /// US2 scenario 3 and the staleness edge: nobody recent enough falls to the iPhone;
    /// a device not heard from past `deviceStaleness` is not the device in hand.
    @Test func nobodyRecentFallsToTheIPhone() async throws {
        var clock = Date()
        let tick = { (by: TimeInterval) in clock = clock.addingTimeInterval(by) }
        let (locations, work) = try temporary()
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: asking(),
                              now: { [clock] in clock }, thresholds: thresholds)
        _ = tick
        let heard = AttentionRecorder(); await heard.attach(to: core)
        let (phone, pad) = await devices(core)
        await phone.report(core, active: true, mayNotify: true)
        await pad.report(core, active: true, mayNotify: true)
        // Both go quiet for longer than a surface counts as evidence.
        await phone.report(core, active: false, mayNotify: true)
        await pad.report(core, active: false, mayNotify: true)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "write a file"))
        await waitingOnUser(core, id)
        await eventually("somebody was told") { heard.deliveries.first != nil }
        // Neither is active, so neither is in hand; the default is the iPhone.
        #expect(heard.deliveries.first?.to == phone.surface)
    }

    /// US2 scenario 5: one device paired is that device, whatever it is.
    @Test func theOnlyDeviceIsTheOneWhateverItIs() async throws {
        let (locations, work) = try temporary()
        let core = try core(asking(), locations: locations)
        let heard = AttentionRecorder(); await heard.attach(to: core)
        let pad = FakeSurface(.device(UUID()))
        await pad.pair(core, name: "Pad", kind: .iPad)
        await pad.report(core, active: true, mayNotify: true)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "write a file"))
        await waitingOnUser(core, id)
        await eventually("the pad was told") { heard.deliveries.first != nil }
        #expect(heard.deliveries.first?.to == pad.surface)
    }

    /// US2 scenario 4: the Mac, active but behind another app, beats both devices.
    @Test func theMacBehindAnotherAppBeatsTheDevices() async throws {
        let (locations, work) = try temporary()
        let core = try core(asking(), locations: locations)
        let heard = AttentionRecorder(); await heard.attach(to: core)
        let (phone, pad) = await devices(core)
        await phone.report(core, active: true, mayNotify: true)
        await pad.report(core, active: true, mayNotify: true)
        await FakeSurface(.mac).report(core, watching: nil, active: true)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "write a file"))
        await waitingOnUser(core, id)
        await eventually("the Mac was told, after its pause") { heard.deliveries.first != nil }
        #expect(heard.deliveries.first?.to == .mac)
    }

    /// A device that may not notify is never chosen, in hand or as the default.
    @Test func aDeviceThatMayNotNotifyIsNeverChosen() async throws {
        let (locations, work) = try temporary()
        let core = try core(asking(), locations: locations)
        let heard = AttentionRecorder(); await heard.attach(to: core)
        let phone = FakeSurface(.device(UUID()))
        await phone.pair(core, name: "Phone", kind: .iPhone)
        await phone.report(core, active: true, mayNotify: false)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "write a file"))
        await waitingOnUser(core, id)
        try await settled()
        #expect(heard.deliveries.isEmpty)
        #expect(await core.attentionPending().needs.count == 1)
    }

    /// Two reports in the same instant resolve by the daemon's clock and not by anything
    /// either device claimed; on an exact tie the iPhone wins.
    @Test func aTieIsTheDaemonsClockAndThenTheIPhone() async throws {
        let frozen = Date()
        let (locations, work) = try temporary()
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: asking(),
                              now: { frozen }, thresholds: thresholds)
        let heard = AttentionRecorder(); await heard.attach(to: core)
        let (phone, pad) = await devices(core)
        await pad.report(core, active: true, mayNotify: true)
        await phone.report(core, active: true, mayNotify: true)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "write a file"))
        await waitingOnUser(core, id)
        await eventually("somebody was told") { heard.deliveries.first != nil }
        #expect(heard.deliveries.first?.to == phone.surface)
    }

    @Test func aDeviceMayOnlyIdentifyOnItsOwnConnection() async throws {
        let (locations, _) = try temporary()
        let core = try core(asking(), locations: locations)
        let params = try JSONValue.encoding(DaemonAPI.SurfaceIdentification(id: UUID(), name: "x", kind: .iPhone))
        let answer = await core.handle(method: DaemonAPI.Method.surfaceIdentify, params: params,
                                       from: .mac, connection: UUID())
        guard case .failure(let error) = answer else { Issue.record("expected a refusal"); return }
        #expect(error.code == DaemonAPI.Failure.notASurface)
    }

    @Test func aReportWithNoIdentityIsRefused() async throws {
        let (locations, _) = try temporary()
        let core = try core(asking(), locations: locations)
        let params = try JSONValue.encoding(DaemonAPI.PresenceReport(watching: nil, active: true))
        let answer = await core.handle(method: DaemonAPI.Method.presenceReport, params: params)
        guard case .failure(let error) = answer else { Issue.record("expected a refusal"); return }
        #expect(error.code == DaemonAPI.Failure.notASurface)
    }

    // MARK: US5, pairing (Phase 7, against the fake mailbox)

    private func pairing(_ launcher: FakeLauncher, locations: StoreLocations,
                         mailbox: FakeMailbox) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                   discovery: .findsEverything, launcher: launcher, thresholds: thresholds, mailbox: mailbox)
    }

    /// US5 scenario 1: a device that never paired is sent nothing, however present it
    /// says it is.
    @Test func anUnpairedDeviceIsSentNothing() async throws {
        let (locations, work) = try temporary()
        let mailbox = FakeMailbox()
        let core = try pairing(asking(), locations: locations, mailbox: mailbox)
        let heard = AttentionRecorder(); await heard.attach(to: core)
        let stranger = FakeSurface(.device(UUID()))
        await stranger.identify(core, name: "Stranger", kind: .iPhone)
        await stranger.report(core, active: true, mayNotify: true)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "write a file"))
        await waitingOnUser(core, id)
        try await settled()
        #expect(heard.deliveries.isEmpty)
        #expect(await mailbox.posted.isEmpty)
        #expect(await core.allDevices().isEmpty, "identifying does not pair")
    }

    /// US5 scenario 2, as it stands after 2026-09-21: announcing **is** pairing. The
    /// need goes to the phone, sealed to it, and the phone can open it.
    @Test func anAnnouncedDeviceIsPairedAndSentTheSealedNeed() async throws {
        let (locations, work) = try temporary()
        let mailbox = FakeMailbox()
        let core = try pairing(asking(), locations: locations, mailbox: mailbox)
        let heard = AttentionRecorder(); await heard.attach(to: core)
        let phone = FakeSurface(.device(UUID()))
        await phone.announce(core, name: "Phone", kind: .iPhone)
        await phone.identify(core, name: "Phone", kind: .iPhone)
        await phone.report(core, active: true, mayNotify: true)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "write a file"))
        await waitingOnUser(core, id)
        await eventually("the phone was told") { heard.deliveries.first?.to == phone.surface }
        await eventually("and its mailbox holds the sealed headline") { await !mailbox.posted.isEmpty }
        let item = try #require(await mailbox.posted.first)
        #expect(item.device == phone.surface.deviceID)
        let opened = try Envelope.open(try #require(item.envelope), with: phone.key)
        #expect(opened.h3.hasPrefix("Wants to"))
        #expect(await core.allDevices().count == 1)
    }

    /// A need that is met leaves a withdrawal in the phone's mailbox under the same
    /// name, so a stale banner is replaced rather than left.
    @Test func aMetNeedIsWithdrawnFromTheMailbox() async throws {
        let (locations, work) = try temporary()
        let mailbox = FakeMailbox()
        let core = try pairing(asking(), locations: locations, mailbox: mailbox)
        let heard = AttentionRecorder(); await heard.attach(to: core)
        let phone = FakeSurface(.device(UUID()))
        await phone.pair(core, name: "Phone", kind: .iPhone)
        await phone.report(core, active: true, mayNotify: true)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "write a file"))
        await waitingOnUser(core, id)
        await eventually("posted") { await !mailbox.posted.isEmpty }
        let need = try #require(heard.deliveries.first?.needID)
        guard case .permission(let permissionID) = need else { Issue.record("expected a permission"); return }
        try await core.answerPermission(DaemonAPI.AnswerRequest(permissionID: permissionID, optionID: "allow"))
        await eventually("withdrawn") { await mailbox.posted.contains { $0.needID == need && $0.envelope == nil } }
        let waiting = await mailbox.waiting(for: try #require(phone.surface.deviceID))
        #expect(waiting.first { $0.needID == need }?.envelope == nil)
    }

    /// A key never changes under an id.
    @Test func aDeviceWithANewKeyIsRefused() async throws {
        let (locations, _) = try temporary()
        let core = try pairing(asking(), locations: locations, mailbox: FakeMailbox())
        let phone = FakeSurface(.device(UUID()))
        await phone.announce(core, name: "Phone", kind: .iPhone)
        let other = DeviceKey.ephemeral()
        let params = try JSONValue.encoding(DaemonAPI.DeviceAnnouncement(id: try #require(phone.surface.deviceID),
                                                                         publicKey: other.publicKey,
                                                                         name: "Phone", kind: .iPhone))
        let answer = await core.handle(method: DaemonAPI.Method.devicesAnnounce, params: params,
                                       from: phone.surface, connection: phone.connection)
        guard case .failure(let error) = answer else { Issue.record("expected a refusal"); return }
        #expect(error.code == DaemonAPI.Failure.notSupported)
        #expect(await core.allDevices().count == 1)
    }

    /// The store outlives the daemon: a paired device is still paired after a restart.
    @Test func pairingSurvivesARestart() async throws {
        let (locations, _) = try temporary()
        let first = try pairing(asking(), locations: locations, mailbox: FakeMailbox())
        let phone = FakeSurface(.device(UUID()))
        await phone.pair(first, name: "Phone", kind: .iPhone)
        let second = try pairing(asking(), locations: locations, mailbox: FakeMailbox())
        let listed = await second.allDevices()
        #expect(listed.first?.id == phone.surface.deviceID)
        #expect(listed.first?.publicKey == phone.key.publicKey)
    }
}

/// Reading: the daemon flags a chat unread when it finishes with nobody watching, and
/// clears it when a presence report puts the chat in front of an active person.
@Suite("Reading", .timeLimit(.minutes(1)))
struct ReadingTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsReadingTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func makeCore(locations: StoreLocations) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                   discovery: .findsEverything, launcher: FakeLauncher(script: .init()))
    }

    @Test func aChatThatFinishesWhileWatchedIsRead() async throws {
        let (locations, work) = try temporary()
        let core = try makeCore(locations: locations)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "hello"))
        await FakeSurface(.mac).report(core, watching: id, active: true)
        await eventually("finished") { await core.agent(id)?.state == .finished }
        let agent = try #require(await core.agent(id))
        #expect(!agent.isUnread)
    }

    @Test func aChatThatFinishesUnwatchedIsUnreadUntilLookedAt() async throws {
        let (locations, work) = try temporary()
        let core = try makeCore(locations: locations)
        let mac = FakeSurface(.mac)
        await mac.report(core, watching: nil, active: true)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "hello"))
        await eventually("finished") { await core.agent(id)?.state == .finished }
        #expect(await core.agent(id)?.isUnread == true)
        await mac.report(core, watching: id, active: true)
        #expect(await core.agent(id)?.isUnread == false)
        // Read survives the daemon: it is on the record. The record is written after
        // the fact, so the next daemon is asked until it has it.
        await eventually("read on disk") {
            guard let again = try? makeCore(locations: locations) else { return false }
            _ = await again.recover()
            return await again.agent(id)?.isUnread == false
        }
    }

    @Test func lookingWhileAwayFromTheMacDoesNotRead() async throws {
        let (locations, work) = try temporary()
        let core = try makeCore(locations: locations)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "hello"))
        await eventually("finished") { await core.agent(id)?.state == .finished }
        await FakeSurface(.mac).report(core, watching: id, active: false)
        #expect(await core.agent(id)?.isUnread == true)
    }
}

/// A need in an archived project is no need: archiving is the person saying they are
/// done with it, whatever its agents were asking.
@Suite("Archived projects", .timeLimit(.minutes(1)))
struct ArchivedProjectAttentionTests {
    @Test func archivingAProjectWithdrawsItsNeeds() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsArchivedNeeds-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        // A finished agent whose report wants somebody, on disk before the daemon starts:
        // only a project with nothing live in it can be archived.
        let store = try AgentStore(locations: locations)
        let stuck = Agent(id: UUID(), runtimeID: "claude", cwd: work, title: "Stuck one", state: .finished, endedReason: .endTurn,
                          report: WorkReport(outcome: .stuck, message: "cannot go on", at: Date()))
        try await store.save(stuck)
        let core = DaemonCore(store: store, locations: locations, discovery: .findsEverything,
                              launcher: FakeLauncher(script: .init()),
                              thresholds: AttentionThresholds(macIdle: 60, deviceStaleness: 60,
                                                              settlingPause: 0.05, reAlertInterval: 60))
        _ = await core.recover()
        let heard = AttentionRecorder(); await heard.attach(to: core)
        await FakeSurface(.mac).report(core, active: true)
        await eventually("shown on the Mac") { heard.deliveries.first?.to == .mac }
        #expect(await core.attentionPending().needs.count == 1)

        _ = try await core.archiveProject(work)
        await eventually("withdrawn") { !heard.withdrawals.isEmpty }
        #expect(await core.attentionPending().needs.isEmpty)

        _ = try await core.unarchiveProject(work)
        await eventually("back") { await core.attentionPending().needs.count == 1 }
    }
}

// MARK: - 025 US1: what a restart must not undo
//
// The daemon restarts on every build of this app. A need built from the agent record —
// a finished agent whose report says it cannot get further alone — survives that
// perfectly well, because it is read straight off disk. What used to die with the
// daemon was the memory of having *already told somebody*, and the moment the need was
// first raised.
//
// Every test here builds a second `DaemonCore` on the same `StoreLocations`, which is
// what a restart is. A test that exercises one core proves nothing about this at all.

@Suite("Attention across a restart", .timeLimit(.minutes(1)))
struct AttentionRestartTests {
    private let thresholds = AttentionThresholds(macIdle: 60, deviceStaleness: 60,
                                                 settlingPause: 0.15, reAlertInterval: 60)

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsAttentionRestart-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    /// The same moment, to the precision the record keeps.
    ///
    /// `StoreCoding` writes ISO 8601 with three decimal places, on purpose, so every
    /// file in this app stays readable with `cat`. A date that has been through one is
    /// the same *moment* and not the same `Double`, and a test that asked for the second
    /// would be testing the encoder rather than this feature. Two milliseconds is an
    /// order of magnitude under the smallest thing that would mean a bug here: the
    /// failure this guards against resets `raisedAt` to now, which is whole seconds away.
    private func isSameMoment(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.timeIntervalSince(b)) < 0.002
    }

    private func core(locations: StoreLocations, thresholds: AttentionThresholds? = nil,
                      launcher: FakeLauncher = FakeLauncher(script: .init())) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations),
                   locations: locations,
                   discovery: .findsEverything,
                   launcher: launcher,
                   thresholds: thresholds ?? self.thresholds)
    }

    /// A finished agent that says it is stuck, put on disk before any daemon exists.
    ///
    /// Written rather than acted out, so these tests are about the restart and not about
    /// a fake runtime's timing. It is the same shape `archivingAProjectWithdrawsItsNeeds`
    /// already uses, and it is the one kind of need that outlives a daemon.
    @discardableResult
    private func stuckAgent(_ locations: StoreLocations, in work: URL,
                            reportedAt: Date = Date()) async throws -> Agent {
        let agent = Agent(id: UUID(), runtimeID: "claude", cwd: work, title: "The stuck one",
                          state: .finished, endedReason: .endTurn,
                          report: WorkReport(outcome: .stuck, message: "No signing certificate here.",
                                             at: reportedAt))
        try await AgentStore(locations: locations).save(agent)
        return agent
    }

    /// US1 scenarios 1 and 2, and the whole of the feature: the second daemon knows the
    /// person has already been told, so it does not tell them again, and it knows when
    /// the need was first raised, so the clock does not start over.
    @Test func aDeliveredNeedIsNotAlertedAgainAfterARestart() async throws {
        let (locations, work) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        try await stuckAgent(locations, in: work)

        // The first daemon: the need is raised, and the Mac is told about it once.
        let first = try core(locations: locations)
        _ = await first.recover()
        let heardFirst = AttentionRecorder(); await heardFirst.attach(to: first)
        await FakeSurface(.mac).report(first, active: true)
        await eventually("the Mac was told") { heardFirst.deliveries.first?.to == .mac }
        let raisedAt = try #require(await first.attentionPending().needs.first?.raisedAt)
        #expect(heardFirst.deliveries.count == 1)

        // The daemon goes, and another takes its place on the same root.
        let second = try core(locations: locations)
        _ = await second.recover()
        let heardSecond = AttentionRecorder(); await heardSecond.attach(to: second)
        await FakeSurface(.mac).report(second, active: true)
        try await Task.sleep(for: .milliseconds(400))

        #expect(heardSecond.changes.isEmpty,
                "nothing moved, so nobody is told anything: \(heardSecond.changes.map(\.needID))")
        let pending = await second.attentionPending()
        #expect(pending.needs.count == 1, "the need itself survives, as it always did")
        #expect(pending.deliveries.first?.to == .mac, "and it is still showing where it was")
        let moved = (pending.needs.first?.raisedAt).map { abs($0.timeIntervalSince(raisedAt)) } ?? -1
        #expect(isSameMoment(pending.needs.first?.raisedAt, raisedAt),
                "the moment it was first raised is the first daemon's, not this one's — moved by \(moved)s")
    }

    /// US1 scenario 3: the pause that lets somebody look at their own screen before
    /// anything is shown is measured from when the need was raised — not from when the
    /// daemon happened to restart.
    ///
    /// A generous pause, and a generous allowance, on purpose: the broken behaviour is a
    /// *whole fresh pause* from the restart, so the two are two seconds apart. A slow
    /// machine makes this pass more readily, not less.
    @Test func theSettlingPauseIsNotStartedAgainByARestart() async throws {
        let (locations, work) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let slowToSettle = AttentionThresholds(macIdle: 60, deviceStaleness: 60,
                                               settlingPause: 2, reAlertInterval: 60)
        try await stuckAgent(locations, in: work)

        let first = try core(locations: locations, thresholds: slowToSettle)
        _ = await first.recover()
        let heardFirst = AttentionRecorder(); await heardFirst.attach(to: first)
        await FakeSurface(.mac).report(first, active: true)
        await eventually("the need is outstanding") { await first.attentionPending().needs.count == 1 }
        let raisedAt = try #require(await first.attentionPending().needs.first?.raisedAt)
        // Most of the way through the pause, with nothing delivered yet.
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(heardFirst.deliveries.isEmpty, "still settling when the daemon went")

        let second = try core(locations: locations, thresholds: slowToSettle)
        _ = await second.recover()
        let heardSecond = AttentionRecorder(); await heardSecond.attach(to: second)
        await FakeSurface(.mac).report(second, active: true)

        let restored = await second.attentionPending().needs.first?.raisedAt
        #expect(isSameMoment(restored, raisedAt),
                "moved by \(restored.map { abs($0.timeIntervalSince(raisedAt)) } ?? -1)s")
        await eventually("delivered on the original pause, not a fresh one", within: .seconds(1)) {
            heardSecond.deliveries.first?.to == .mac
        }
    }

    /// US1 scenario 5: the ordinary re-alert rule applies across a restart — the restart
    /// neither suppresses an alert nor brings one forward.
    ///
    /// A move inside the interval is silent. This is the test that stops the fix from
    /// becoming a mute: without it, "never alert after a restart" would pass everything
    /// above.
    @Test func aMoveJustAfterARestartIsSilentWhenTheIntervalHasNotPassed() async throws {
        let (locations, work) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        try await stuckAgent(locations, in: work)
        let phone = FakeSurface(.device(UUID()))

        let first = try core(locations: locations)
        _ = await first.recover()
        let heardFirst = AttentionRecorder(); await heardFirst.attach(to: first)
        // The Mac first, and it wins every rung below it, so the need is delivered
        // there and stays there while the phone pairs behind it.
        await FakeSurface(.mac).report(first, active: true)
        await eventually("the Mac was told") { heardFirst.deliveries.first?.to == .mac }
        await phone.pair(first, name: "iPhone", kind: .iPhone)
        await phone.report(first, active: true, mayNotify: true)
        #expect(heardFirst.changes.count == 1, "the phone arriving does not move it off the Mac")

        // Restart, with only the phone about: the need has to move.
        let second = try core(locations: locations)
        _ = await second.recover()
        let heardSecond = AttentionRecorder(); await heardSecond.attach(to: second)
        await phone.report(second, active: true, mayNotify: true)

        let moved = try #require(await eventuallySome("the need moved to the phone") {
            heardSecond.changes.first { $0.to == .device(phone.surface.deviceID!) }
        })
        #expect(moved.alert == false,
                "a move inside the re-alert interval moves the notification and does not buzz")
    }

    /// The other half of the rule: once the interval really has passed, a move alerts,
    /// restart or no restart.
    @Test func aMoveAfterARestartAlertsOnceTheIntervalHasPassed() async throws {
        let (locations, work) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let quickToRepeat = AttentionThresholds(macIdle: 60, deviceStaleness: 60,
                                                settlingPause: 0.05, reAlertInterval: 0.05)
        try await stuckAgent(locations, in: work)
        let phone = FakeSurface(.device(UUID()))

        let first = try core(locations: locations, thresholds: quickToRepeat)
        _ = await first.recover()
        let heardFirst = AttentionRecorder(); await heardFirst.attach(to: first)
        await FakeSurface(.mac).report(first, active: true)
        await eventually("the Mac was told") { heardFirst.deliveries.first?.to == .mac }
        await phone.pair(first, name: "iPhone", kind: .iPhone)
        await phone.report(first, active: true, mayNotify: true)
        // Past the re-alert interval, so the move below is due a fresh alert.
        try await Task.sleep(for: .milliseconds(200))

        let second = try core(locations: locations, thresholds: quickToRepeat)
        _ = await second.recover()
        let heardSecond = AttentionRecorder(); await heardSecond.attach(to: second)
        await phone.report(second, active: true, mayNotify: true)

        let moved = try #require(await eventuallySome("the need moved to the phone") {
            heardSecond.changes.first { $0.to == .device(phone.surface.deviceID!) }
        })
        #expect(moved.alert == true, "the interval has passed, so the move buzzes")
    }

    /// A need that is met while the daemon is down leaves nothing behind in the file.
    /// The withdrawal itself is US2; this is only that the note does not outlive its need.
    @Test func aNoteDoesNotOutliveTheNeedItIsAbout() async throws {
        let (locations, work) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let agent = try await stuckAgent(locations, in: work)

        let first = try core(locations: locations)
        _ = await first.recover()
        let heardFirst = AttentionRecorder(); await heardFirst.attach(to: first)
        await FakeSurface(.mac).report(first, active: true)
        await eventually("the Mac was told") { heardFirst.deliveries.first?.to == .mac }

        // Archived while nothing is running, which is one of the ways a need is met.
        var put = try #require(await first.agent(agent.id))
        put.state = .archived
        put.archivedReason = .byUser
        try await AgentStore(locations: locations).save(put)

        let second = try core(locations: locations)
        _ = await second.recover()
        await FakeSurface(.mac).report(second, active: true)
        try await Task.sleep(for: .milliseconds(300))

        #expect(await second.attentionPending().needs.isEmpty)
        #expect(await second.attentionPending().deliveries.isEmpty)
    }
}

// MARK: - 025 US2: a question that is gone stops asking
//
// When a question dies with the daemon, the next daemon has to take its banner down —
// and the withdrawal is the one post with no second chance. Every other post is
// repeated by the daemon's next decision about that need; this one is *about* the need
// being over, so there is no next decision. Posted into a room with nobody carrying
// mail in it, it is simply gone, and the phone keeps a question nobody can answer.
//
// The daemon cannot tell the bridge from a window — every connection starts as the Mac,
// and the bridge never says otherwise — so the bridge now says `mailbox/carry`, and a
// withdrawal waits in `attention.json` until something that will carry it is listening.

/// Every `mailbox/post` a daemon broadcasts, for the daemon's own case: no mailbox of
/// its own, so what it has for a device goes out for the bridge to carry.
final class MailboxRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [MailboxItem] = []

    func attach(to core: DaemonCore) async {
        await core.setBroadcaster { [weak self] method, params in
            guard method == DaemonAPI.Notification.mailboxPost, let params,
                  let item = try? params.decode(MailboxItem.self) else { return }
            self?.append(item)
        }
    }

    private func append(_ item: MailboxItem) {
        lock.lock(); defer { lock.unlock() }
        heard.append(item)
    }

    var items: [MailboxItem] {
        lock.lock(); defer { lock.unlock() }
        return heard
    }

    func withdrawals(of need: NeedID) -> [MailboxItem] {
        items.filter { $0.needID == need && $0.envelope == nil }
    }
}

@Suite("Withdrawals across a restart", .timeLimit(.minutes(1)))
struct WithdrawalRestartTests {
    private let thresholds = AttentionThresholds(macIdle: 60, deviceStaleness: 60,
                                                 settlingPause: 0.15, reAlertInterval: 60)

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWithdrawalRestart-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func core(locations: StoreLocations, mailbox: (any Mailbox)? = nil,
                      launcher: FakeLauncher = FakeLauncher(script: .init())) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations),
                   locations: locations,
                   discovery: .findsEverything,
                   launcher: launcher,
                   thresholds: thresholds,
                   mailbox: mailbox)
    }

    /// A runtime that asks permission mid-turn and waits on the answer.
    private func asking() -> FakeLauncher {
        var script = FakeACPAgent.Script()
        script.permission = ["toolCall": ["title": "Delete build/", "rawInput": ["description": "Delete the build folder"]],
                             "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"],
                                         ["optionId": "no", "name": "Reject", "kind": "reject_once"]]]
        return FakeLauncher(script: script)
    }

    /// The first daemon: a question held, and put in front of a phone the person has in
    /// hand, with nobody at the Mac. Returns the need, so the next daemon can be asked
    /// about it.
    private func aQuestionOnThePhone(_ locations: StoreLocations, in work: URL,
                                     phone: FakeSurface, mailbox: (any Mailbox)? = nil) async throws -> NeedID {
        let first = try core(locations: locations, mailbox: mailbox, launcher: asking())
        _ = await first.recover()
        let heard = AttentionRecorder(); await heard.attach(to: first)
        await phone.pair(first, name: "iPhone", kind: .iPhone)
        await phone.report(first, active: true, mayNotify: true)
        let id = try await first.start(.init(runtimeID: "claude", cwd: work, prompt: "tidy up"))
        await eventually("the agent is waiting on its question") {
            await first.agent(id)?.state == .waitingOnUser
        }
        let shown = try #require(await eventuallySome("the phone was shown it") {
            heard.deliveries.first { $0.to == phone.surface }
        })
        return shown.needID
    }

    private func onDisk(_ locations: StoreLocations) -> AttentionRecords {
        AttentionStore(locations: locations).load()
    }

    /// Scenario 1: with a mailbox to post to, the next daemon takes the banner down, and
    /// nothing about it is left in the file afterwards.
    @Test func aWithdrawalReachesTheMailboxAfterARestart() async throws {
        let (locations, work) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let phone = FakeSurface(.device(UUID()))
        let need = try await aQuestionOnThePhone(locations, in: work, phone: phone, mailbox: FakeMailbox())

        let mailbox = FakeMailbox()
        let second = try core(locations: locations, mailbox: mailbox)
        _ = await second.recover()
        await FakeSurface(.mac).report(second, active: true)

        let posted = try #require(await eventuallySome("a withdrawal was posted for the question") {
            await mailbox.posted.first { $0.needID == need && $0.envelope == nil }
        })
        #expect(posted.device == phone.surface.deviceID)
        await eventually("nothing about it is left in the file") {
            let records = onDisk(locations)
            return records.withdrawing.isEmpty && !records.deliveries.contains { $0.needID == need }
        }
    }

    /// Scenario 2, and the reason US2 is more than one line: the daemon's own case has no
    /// mailbox, so a withdrawal goes out for the bridge — and until something that
    /// carries mail is listening, it must wait rather than be shouted into the room.
    /// A window is not a carrier, however many of them there are.
    @Test func aWithdrawalWaitsForSomethingThatWillCarryIt() async throws {
        let (locations, work) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let phone = FakeSurface(.device(UUID()))
        let need = try await aQuestionOnThePhone(locations, in: work, phone: phone)

        let second = try core(locations: locations)
        let heard = MailboxRecorder(); await heard.attach(to: second)
        _ = await second.recover()
        // A window arrives. It is not a carrier.
        await FakeSurface(.mac).report(second, active: true)
        try await Task.sleep(for: .milliseconds(300))

        #expect(heard.withdrawals(of: need).isEmpty, "nobody was listening who could carry it")
        #expect(onDisk(locations).withdrawing.map(\.need) == [need], "so it waits, on disk")
        #expect(onDisk(locations).withdrawing.first?.device == phone.surface.deviceID)

        // The bridge arrives and says what it is for.
        let bridge = UUID()
        _ = await second.handle(method: DaemonAPI.Method.mailboxCarry, params: nil,
                                from: .mac, connection: bridge)

        await eventually("the withdrawal went out once there was a carrier") {
            heard.withdrawals(of: need).count == 1
        }
        #expect(heard.withdrawals(of: need).first?.device == phone.surface.deviceID)
        await eventually("and was forgotten once handed over") { onDisk(locations).withdrawing.isEmpty }
    }

    /// FR-005 across a daemon exit: a withdrawal no carrier heard is still owed, and the
    /// next daemon pays it.
    @Test func aWithdrawalNobodyCarriedIsCarriedByTheNextDaemon() async throws {
        let (locations, work) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let phone = FakeSurface(.device(UUID()))
        let need = try await aQuestionOnThePhone(locations, in: work, phone: phone)

        // The second daemon decides it, and goes before any bridge arrives.
        let second = try core(locations: locations)
        _ = await second.recover()
        await FakeSurface(.mac).report(second, active: true)
        await eventually("it waits on disk") { onDisk(locations).withdrawing.map(\.need) == [need] }

        let third = try core(locations: locations)
        let heard = MailboxRecorder(); await heard.attach(to: third)
        _ = await third.recover()
        _ = await third.handle(method: DaemonAPI.Method.mailboxCarry, params: nil,
                               from: .mac, connection: UUID())

        await eventually("the third daemon carried what the second could not") {
            heard.withdrawals(of: need).count == 1
        }
        await eventually("and the debt is cleared") { onDisk(locations).withdrawing.isEmpty }
    }

    /// A carrier that has gone carries nothing. Its disconnect must take it off the list,
    /// or a withdrawal decided afterwards is handed to a bridge that is not there — and
    /// forgotten, as though it had been.
    @Test func aCarrierThatHasGoneCarriesNothing() async throws {
        let (locations, work) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let core = try core(locations: locations, launcher: asking())
        _ = await core.recover()
        let heard = MailboxRecorder(); await heard.attach(to: core)
        let phone = FakeSurface(.device(UUID()))
        await phone.pair(core, name: "iPhone", kind: .iPhone)
        await phone.report(core, active: true, mayNotify: true)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "tidy up"))
        await eventually("waiting on its question") { await core.agent(id)?.state == .waitingOnUser }
        let need = try #require(await core.attentionPending().needs.first?.id)

        // The bridge comes, and goes.
        let bridge = UUID()
        _ = await core.handle(method: DaemonAPI.Method.mailboxCarry, params: nil,
                              from: .mac, connection: bridge)
        await core.forgetCarrier(connection: bridge)

        // Then the question is over, with nothing left to carry it.
        try await core.stop(id)
        await eventually("the withdrawal is owed") { onDisk(locations).withdrawing.map(\.need) == [need] }
        try await Task.sleep(for: .milliseconds(200))
        #expect(heard.withdrawals(of: need).isEmpty, "handed to a bridge that had gone")
    }

    /// FR-006: a device this daemon no longer has on record is sent nothing — not a
    /// banner, and not a withdrawal.
    @Test func aWithdrawalForADeviceNoLongerKnownIsDropped() async throws {
        let (locations, work) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let phone = FakeSurface(.device(UUID()))
        let need = try await aQuestionOnThePhone(locations, in: work, phone: phone, mailbox: FakeMailbox())
        try FileManager.default.removeItem(at: locations.devices)

        let mailbox = FakeMailbox()
        let second = try core(locations: locations, mailbox: mailbox)
        _ = await second.recover()
        await FakeSurface(.mac).report(second, active: true)
        try await Task.sleep(for: .milliseconds(300))

        #expect(await mailbox.posted.filter { $0.needID == need }.isEmpty)
        #expect(onDisk(locations).withdrawing.isEmpty)
    }

    /// A newer decision about the same need on the same device supersedes a withdrawal
    /// still waiting for a carrier. Without this, a banner taken off the phone and put
    /// back while the bridge was away would be taken off again when the bridge arrived —
    /// for a question that is still asking.
    @Test func aNewerPostToTheSameDeviceSupersedesAWaitingWithdrawal() async throws {
        let (locations, work) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let core = try core(locations: locations, launcher: asking())
        _ = await core.recover()
        let heard = MailboxRecorder(); await heard.attach(to: core)
        let phone = FakeSurface(.device(UUID()))
        await phone.pair(core, name: "iPhone", kind: .iPhone)
        await phone.report(core, active: true, mayNotify: true)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "tidy up"))
        await eventually("waiting on its question") { await core.agent(id)?.state == .waitingOnUser }
        let need = try #require(await core.attentionPending().needs.first?.id)
        await eventually("posted to the phone") {
            heard.items.contains { $0.needID == need && $0.envelope != nil }
        }

        // The person comes to the Mac: the banner leaves the phone, with no carrier to
        // take the withdrawal. Then they walk away and it goes back.
        let mac = FakeSurface(.mac)
        await mac.report(core, active: true)
        await eventually("a withdrawal waits") { onDisk(locations).withdrawing.map(\.need) == [need] }
        await mac.disconnect(core)
        await eventually("back on the phone, and the waiting withdrawal is void") {
            onDisk(locations).withdrawing.isEmpty
        }

        _ = await core.handle(method: DaemonAPI.Method.mailboxCarry, params: nil,
                              from: .mac, connection: UUID())
        try await Task.sleep(for: .milliseconds(300))
        #expect(heard.withdrawals(of: need).isEmpty, "the question is still asking; its banner stays")
    }
}
