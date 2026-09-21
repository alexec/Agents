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

    private func core(_ launcher: FakeLauncher, locations: StoreLocations) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations),
                   locations: locations,
                   discovery: .findsEverything,
                   launcher: launcher,
                   thresholds: thresholds)
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

    /// US5 scenario 2: announced and waiting is not paired.
    @Test func aDeviceWaitingForApprovalIsSentNothing() async throws {
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
        try await settled()
        #expect(heard.deliveries.isEmpty)
        #expect(await mailbox.posted.isEmpty)
        let listed = await core.allDevices()
        #expect(listed.count == 1 && listed.first?.isApproved == false)

        // Then the person says yes: the need goes to the phone, sealed to it.
        await phone.approve(core)
        await eventually("the phone was told") { heard.deliveries.first?.to == phone.surface }
        await eventually("and its mailbox holds the sealed headline") { await !mailbox.posted.isEmpty }
        let item = try #require(await mailbox.posted.first)
        #expect(item.device == phone.surface.deviceID)
        let opened = try Envelope.open(try #require(item.envelope), with: phone.key)
        #expect(opened.h3.hasPrefix("Wants to"))
    }

    /// US5 scenario 3 and SC-007: revoked is deleted, its mailbox is emptied, and what
    /// was showing there is decided again without it.
    @Test func aRevokedDeviceIsSentNothingAndItsMailboxIsEmpty() async throws {
        let (locations, work) = try temporary()
        let mailbox = FakeMailbox()
        let core = try pairing(asking(), locations: locations, mailbox: mailbox)
        let heard = AttentionRecorder(); await heard.attach(to: core)
        let phone = FakeSurface(.device(UUID()))
        await phone.pair(core, name: "Phone", kind: .iPhone)
        await phone.report(core, active: true, mayNotify: true)
        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "write a file"))
        await waitingOnUser(core, id)
        await eventually("the phone was told") { heard.deliveries.first?.to == phone.surface }
        await eventually("posted") { await !mailbox.posted.isEmpty }

        let params = try JSONValue.encoding(DaemonAPI.DeviceRequest(id: try #require(phone.surface.deviceID)))
        _ = await core.handle(method: DaemonAPI.Method.devicesRevoke, params: params, from: .mac, connection: UUID())
        await eventually("emptied") { await !mailbox.emptied.isEmpty }
        #expect(await mailbox.waiting(for: try #require(phone.surface.deviceID)).isEmpty)
        #expect(await core.allDevices().isEmpty)
        await eventually("moved off the phone") { heard.changes.last?.to == nil }
        try await settled()
        #expect(await mailbox.posted.isEmpty, "nothing more is posted to a device that is gone")

        // A revoked id is nobody: another announce with another key is a new device.
        let again = await phone.announce(core, name: "Phone", kind: .iPhone)
        guard case .success = again else { Issue.record("a revoked id may announce afresh"); return }
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
        #expect(listed.first?.isApproved == true)
        #expect(listed.first?.publicKey == phone.key.publicKey)
    }
}
