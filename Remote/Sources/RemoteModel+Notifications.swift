import AgentsKitCore
import BackgroundTasks
import Foundation
import Observation
import SwiftUI
import UIKit
import WidgetKit

/// The remote's state, part of `RemoteModel` (#5383): see `RemoteModel.swift`.
extension RemoteModel {
    // MARK: Beside the notification loop (#175)

    /// One reload per folder at a time; a change while one is under way is in its answer.
    func reloadLabelVocabulary(in folder: URL) {
        guard labelsReloading.insert(folder).inserted else { return }
        Task {
            await loadLabelVocabulary(in: folder)
            labelsReloading.remove(folder)
        }
    }

    func reloadRuntimes() {
        guard !runtimesReloading else { return }
        runtimesReloading = true
        Task {
            await refreshRuntimes()
            runtimesReloading = false
        }
    }

    func toNotifier(_ work: @escaping @MainActor (DeviceNotifier) async -> Void) {
        let before = notifierTail
        let notifier = notifier
        notifierTail = Task {
            await before?.value
            await work(notifier)
        }
    }

    /// The widget's file written once for a burst of notifications, not once for each.
    func publishAttentionSoon() {
        guard attentionPublishing == nil else { return }
        attentionPublishing = Task {
            try? await Task.sleep(for: .milliseconds(500))
            attentionPublishing = nil
            publishAttention()
        }
    }

    /// A call that changes something, sent so that it happens once even if the link
    /// changes under it (046, FR-003). Its params carry the id the Mac dedups — a send's
    /// `sendID`, a start's `requestID` — or it is one the Mac can safely do twice (stop,
    /// archive). A call lost with the connection is sent once more, unchanged, as soon
    /// as the Mac is back.
    ///
    /// Every wait in it is bounded (#208). The call is held only while the host answers
    /// pings; the wait for the Mac to come back is at most `sendPatience`, and none at
    /// all from inside the reconnect loop's own catching up, which would be the loop
    /// waiting on itself. Out of patience it is `MacAway`: the caller keeps what was
    /// typed, and the person's retry is the same send. A call to another host whose
    /// link went is `HostAway` at once: that host's watch brings it back, not this
    /// phone's own reconnect.
    @discardableResult
    func sendOnce(_ method: String, _ params: some Encodable & Sendable,
                          on named: MachineRef? = nil) async throws -> JSONValue {
        let client = try client(for: params, on: named)
        let patience = Self.sendPatience
        do {
            return try await client.callWhileAnswering(method, params, checkingEvery: patience)
        } catch is JSONRPCTransportError {
        } catch DaemonClient.ConnectError.couldNotConnect {
        }
        guard client === self.client else {
            if let host = named ?? otherHost(named: params) {
                reachableHosts.remove(host)
                throw HostAway(host: host)
            }
            throw MacAway()
        }
        guard await reconnect.waitForHost(within: patience) else {
            note("link: \(method) not sent; the Mac did not come back in \(patience)")
            throw MacAway()
        }
        return try await client.callWhileAnswering(method, params, checkingEvery: patience)
    }

    /// Catch up with the Mac: after every connection, and on a pull to refresh (#175).
    ///
    /// Only what is on screen: the folders, the first page of live agents and what is
    /// waiting on a person in one call, then the open chat, then whatever the pages on
    /// screen show. The rest is read when a page that shows it opens. One at a time, and
    /// one catch-up at a time: a pull during a reconnect waits for the reconnect's.
    func catchUp() async {
        if let running = catchingUp {
            await running.value
            return
        }
        let running = Task { await runCatchUp() }
        catchingUp = running
        await running.value
        catchingUp = nil
    }

    func runCatchUp() async {
        let began = ContinuousClock.now
        let plan = parts.plan(chat: selection)
        // The snapshot carries the parts on screen, the disk and the store notes (#884):
        // one round trip through the relay, not one a part. A host that predates that
        // carries none of them, and each is asked for on its own.
        var carried: DaemonAPI.CatchUpSnapshot?
        for step in plan.steps {
            switch step {
            case .snapshot: carried = await refreshSnapshot(with: plan.parts)
            case .chat: await loadTranscript()
            case .part(let part):
                if carried?.carried.contains(part) != true { await load(part) }
            }
        }
        // Sessions in scenes of their own (#888), as the main scene's chat.
        for chat in popouts.values { await loadTranscript(of: chat) }
        // The person's display choices (#1033): the sidebar and every chat read them.
        await refreshDisplayPreferences()
        // The organisation's strip is on every page (#998), so it is read on every catch-up.
        await refreshPolicyState()
        // What the Mac could not read (#205, #223), at the foot of the folders list.
        if carried?.storeNotes == nil { await refreshStoreNotes() }
        await settleUnsettledStart()
        await reopenStartChoices()
        settleSelection()
        // Once the counts have landed, so the widget's number is this refresh's number.
        // Against the file, not the last write: a push may have laid a guess over it (#1046).
        lastPublished = nil
        publishAttention()
        liveActivities.settle(with: work)
        if let pendingOpen { open(pendingOpen) }
        // The Summary row (#3721): shown only while the daily summary is on, with its newest page.
        async let dailySummary: Void = refreshDailySummarySettings()
        async let summaries: Void = refreshSummaryPages()
        // The Multiplier page (#4116), on the iPad's empty detail as well as its row.
        async let multiplier: Void = refreshMultiplier()
        async let achievements: Void = refreshAchievements()
        async let moving: Void = refreshMoves(on: .mac, through: client)
        _ = await (dailySummary, summaries, multiplier, achievements, moving)
        if let pendingNeed {
            self.pendingNeed = nil
            if let agentID = agentID(forNeedToken: pendingNeed) { open(agentID) } else { openUnheld(needToken: pendingNeed) }
        }
        note("catch-up: \(plan.steps.count) steps (\(plan.parts.map(\.rawValue).sorted().joined(separator: ", "))), "
             + "\(carried?.carried.count ?? 0) carried, in \(ContinuousClock.now - began)")
    }

    /// Folders, the first page of live agents, and what waits on a person: one call to a
    /// host that knows `client/catchUp`, one per part to one that does not. With them,
    /// `parts`, the disk and the store notes, from a host that knows to send them (#884).
    /// The snapshot, or nil when it failed.
    func refreshSnapshot(with parts: Set<CatchUpPart>) async -> DaemonAPI.CatchUpSnapshot? {
        let snapshot: DaemonAPI.CatchUpSnapshot
        do {
            // Only what changed since the point held (#4794): the last catch-up's, or the copy's
            // at launch. A host that cannot say what changed since then sends the first page.
            var asked = DaemonAPI.CatchUpRequest.firstPage
            asked.changedSince = work.listPoint(of: .mac)
            snapshot = try await client.catchUp(.init(agents: asked, parts: CatchUpPart.allCases.filter(parts.contains)))
        } catch {
            note("catch-up: the snapshot failed: \(error)")
            return nil
        }
        work.replaceFolders(snapshot.folders, from: .mac)
        pruneFolderDefaults(of: .mac, listed: snapshot.folders)
        startHostMoved()
        lookForShared()
        if let changes = snapshot.agentChanges, !changes.all {
            work.takeChanges(snapshot.agents, changes, from: .mac)
            // A first page's worth held means there may be more, a folder at a time.
            let live = work.agents.lazy.filter { $0.host == .mac && $0.state != .archived }.count
            moreLiveAgents = moreLiveAgents || live >= DaemonAPI.CatchUpRequest.firstPage.pageSize
        } else {
            takeLiveAgents(snapshot.agents, page: DaemonAPI.CatchUpRequest.firstPage)
            work.notePoint(snapshot.agentChanges, of: .mac)
        }
        work.replacePermissions(snapshot.permissions)
        work.replaceElicitations(snapshot.elicitations)
        work.replaceAttention(snapshot.attention)
        work.setResuming(snapshot.resuming)
        toNotifier { [deviceID = self.deviceID] notifier in await notifier.sweep(keeping: snapshot.attention, me: .device(deviceID)) }
        if let notes = snapshot.storeNotes { work.replaceStoreNotes(notes) }
        if let workflows = snapshot.workflows { work.replaceWorkflows(workflows) }
        if let pins = snapshot.pins { work.replacePins(pins) }
        if let leases = snapshot.leases {
            work.replaceLeases(leases.leases)
            work.replaceHostedMCP(leases.hosted)
            work.replaceMCPHealth(leases.health)
        }
        await refreshRequests()
        if let selectedFolder { await fillFolder(selectedFolder) }
        return snapshot
    }

    /// A page showing `parts` appeared: read the ones not read on this connection.
    func showing(_ shown: Set<CatchUpPart>) async {
        let unread = parts.appeared(shown)
        for part in CatchUpPart.allCases where unread.contains(part) {
            await load(part)
        }
    }

    func notShowing(_ shown: Set<CatchUpPart>) {
        parts.disappeared(shown)
    }

    func load(_ part: CatchUpPart) async {
        switch part {
        case .workflows: await refreshWorkflows()
        case .pins: await refreshPins()
        case .leases: await refreshLeases()
        case .runtimes: await refreshRuntimes()
        case .allowances: await refreshRuntimeAllowances()
        case .modes: await refreshModes()
        case .sandbox:
            await refreshSandboxSettings()
            await refreshClientPermissions()
            await refreshAuto()
        case .costs: await refreshCostState()
        }
    }

    // MARK: Where this device is (021)

    /// The app came to the front or went behind. `.active` is foreground and unlocked,
    /// which is what "in the person's hands" means on a device.
    ///
    /// Each scene says its own (#888): the app is in front while any of them is.
    func scenePhase(_ phase: ScenePhase, of scene: UUID) {
        if phase == .background { Self.scheduleWidgetRefresh() }
        let wasActive = scenesActive.isEmpty == false
        if phase == .active { scenesActive.insert(scene) } else { scenesActive.remove(scene) }
        let isActive = !scenesActive.isEmpty
        guard wasActive != isActive || !hasHeardAPhase else { return }
        hasHeardAPhase = true
        let phase: ScenePhase = isActive ? .active : phase
        presence?.scenePhase(phase)
        if phase == .active {
            // Share ▸ Agent Loops may have left something while this was away (#4915).
            lookForShared()
            attentionRefreshTask?.cancel()
            attentionRefreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(300))
                    guard !Task.isCancelled else { break }
                    self?.publishAttention()
                }
            }
            Task {
                await goBackNow(.wake)
                await refreshAttention()
                // A silent push is best effort, so a need that moved while the app was
                // shut may have been missed; the model is now as true as it can be.
                publishAttention()
                liveActivities.settle(with: work)
            }
        } else {
            attentionRefreshTask?.cancel()
            attentionRefreshTask = nil
            publishAttention()
        }
    }

    var kind: Device.Kind {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: .iPhone
        case .pad: .iPad
        default: .unknown
        }
    }

    /// `devices/announce`: who this is, once per connection, so the Mac's record of it
    /// keeps its name and when it was last seen. Pairing is the scanned code
    /// (`pair(scanned:)`); on a paired device's own link this only updates the record.
    func announce() async {
        guard let key else { return }
        do {
            let reply = try await client.call(
                DaemonAPI.Method.devicesAnnounce,
                DaemonAPI.DeviceAnnouncement(id: deviceID, publicKey: key.publicKey,
                                             name: UIDevice.current.name, kind: kind),
                returning: DaemonAPI.AnnounceReply.self)
            thisDevice = reply.device
            note("pairing: announced as \(deviceID)")
        } catch {
            note("pairing: announce failed: \(error)")
        }
        subscribeOnce()
        await sendPushToken()
        liveActivities.sayTokens()
    }

    /// The system gave this device its APNs token: the control plane hears it now if the
    /// link is up, else on the next announce.
    func pushTokenArrived(_ token: Data) {
        pushToken = token
        guard isConnected else { return }
        Task { await sendPushToken() }
    }

    /// `clients/setPushToken` (#1460): the token, to the control plane only, so it can push
    /// here when no Mac host relays notices. What it pushes is sealed to this device's key.
    /// A Mac's own daemon, with no control plane, does not know the method; nothing is lost.
    func sendPushToken() async {
        guard let pushToken else { return }
        do {
            try await client.call(DaemonAPI.Method.clientsSetPushToken,
                                  DaemonAPI.PushToken(token: pushToken, environment: .ofThisBuild))
            note("push: token given to the control plane")
        } catch {
            note("push: the token was not taken: \(error)")
        }
    }

    /// `clients/setActivityToken` (#1744): a Live Activity's push token, to the control plane
    /// only, so it can update the activity while this app is not running; nil when it ended.
    /// A Mac's own daemon does not know the method; the app's own updates go on.
    func sendActivityToken(_ agentID: UUID, _ token: Data?, _ startedAt: Date) async {
        do {
            try await client.call(DaemonAPI.Method.clientsSetActivityToken,
                                  DaemonAPI.ActivityToken(agentID: agentID, token: token, environment: .ofThisBuild,
                                                          startedAt: startedAt))
            note("live activity: token for \(agentID) \(token == nil ? "taken back" : "given") to the control plane")
        } catch {
            note("live activity: the token for \(agentID) was not taken: \(error)")
        }
    }

    /// Ask CloudKit to push this device's mailbox items here. Idempotent on the server
    /// — the subscriptions have stable ids — so once per launch is plenty.
    func subscribeOnce() {
        guard thisDevice != nil, !subscribed else { return }
        subscribed = true
        Task {
            // Permission first, so the Mac hears `mayNotify` and may choose this device.
            await notifier.requestIfUndetermined()
            do {
                try await CloudKitMailbox().subscribe(device: deviceID)
                note("mailbox: subscribed")
            } catch {
                note("mailbox: subscribe failed: \(error)")
                subscribed = false
            }
        }
    }

    // MARK: A push arrived (021 T077, T079)

    /// A silent push: a need moved here without a buzz, moved away, or was met. The
    /// loud ones never come here — `RemoteNotify` turns those into banners before the
    /// system shows them. Everything this does is to local notifications, and it
    /// decides nothing about where the need belongs.
    func receivedPush(_ userInfo: [AnyHashable: Any]) async {
        // The Mac's count moved (#1163): a need met there, a finish read. Nothing to show.
        if let count = CloudKitMailbox.pushedCount(from: userInfo) {
            note("push: count")
            await showOnTheWidget(count)
            return
        }
        // What kind of push, never its payload: that is the person's work (#175).
        let fromControl = ControlPush.isControlPush(userInfo)
        note("push: \(fromControl ? "control plane" : "mailbox")")
        // The mailbox's, or the control plane's own (#1460).
        guard let pushed = fromControl ? ControlPush.pushed(from: userInfo, key: key) : CloudKitMailbox.pushed(from: userInfo)
        else { return }
        let headline = pushed.headline
            ?? pushed.envelope.flatMap { envelope in key.flatMap { try? Envelope.open(envelope, with: $0) } }
        // A need has moved here or away, which is the one thing the widget counts (#1046).
        await showOnTheWidget(AttentionPush(need: pushed.needID, headline: headline,
                                            withdrawn: pushed.withdraws,
                                            count: pushed.count))
        if pushed.withdraws {
            notifier.withdraw(pushed.token)
            return
        }
        guard let headline else { return }
        notifier.show(headline, needID: pushed.needID, alert: pushed.alert)
    }

    /// A push, on the widget (#1046). Connected, the Mac is asked what waits and the whole
    /// is written. Woken in the background with no link, the push is laid over the file,
    /// since the model is as old as the last time the app ran; the count it carries is the
    /// Mac's, and the badge shows it too (#1163).
    func showOnTheWidget(_ push: AttentionPush) async {
        if isConnected {
            // Whole, not only what waits: a guarded change's Needs You row rides on its
            // folder's summary, and the agent's state on its record (#1045).
            await catchUp()
        } else if let written = AttentionSnapshotStore.apply(push) {
            shownFromAPush(written)
        }
    }

    /// The Mac's count on its own (#1163). Connected, the model already says it.
    func showOnTheWidget(_ count: AttentionCount) async {
        if isConnected {
            publishAttention()
        } else if let written = AttentionSnapshotStore.apply(count) {
            shownFromAPush(written)
        }
    }

    /// A push wrote the file: the widget and the badge show what it wrote.
    func shownFromAPush(_ written: AttentionSnapshot) {
        lastPublished = nil
        notifier.setBadgeCount(written.total)
        WidgetCenter.shared.reloadTimelines(ofKind: AttentionSnapshot.widgetKind)
    }

    /// Ask for the next background refresh, a quarter of an hour on at the soonest: the
    /// widget's own staleness (#1046). The system decides when, or whether.
    nonisolated static func scheduleWidgetRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: widgetRefreshTask)
        request.earliestBeginDate = Date(timeIntervalSinceNow: AttentionSnapshot.staleness)
        BGTaskScheduler.shared.submitTaskRequest(request) { _ in }
    }

    /// The system's background refresh (#1046): back in touch for a moment, caught up,
    /// and the widget written, with no push and nobody opening the app.
    func refreshInBackground() async {
        note("widget: background refresh")
        await goBackNow(.wake)
        let deadline = ContinuousClock.now + .seconds(20)
        while !isConnected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard isConnected else { return }
        await catchUp()
    }

    /// Open one conversation from a banner, as the sidebar's pick (#226). A banner tapped
    /// before the agents have arrived — a cold launch — is kept and honoured once they
    /// have.
    func open(_ agentID: UUID) {
        guard work.agent(agentID) != nil else {
            pendingOpen = agentID
            return
        }
        pendingOpen = nil
        // A banner is about the agent, not whatever page was open over the folder. The
        // chat is the detail's own page (#226), not a push over the folder's, so there
        // is no push for a collapsing split view to drop.
        sidebarItem = .session(agentID)
    }

    /// A folder's page, from a banner with no session behind it (#531): where a change
    /// git brought to its files is asked. The phone holds the Mac's folders only.
    func openFolder(_ folder: URL) {
        sidebarItem = .folder(work.folder(folder)?.key ?? FolderKey(host: .mac, folder: folder))
    }

    /// Open what a need is about, from a banner or a widget row (#1046). A need the
    /// model does not hold yet (a cold launch, a wake) is kept and opened once caught up,
    /// as `open(_:)` keeps an agent (#1045).
    func open(needToken token: String) {
        // A notice's line (#2860): gone to and lit once its chat has settled.
        if let line = NeedID.noticeEntry(fromToken: token) { focusedEntry = line }
        if let agentID = agentID(forNeedToken: token) {
            pendingNeed = nil
            open(agentID)
        } else if catchingUp != nil || !isConnected {
            pendingNeed = token
        } else {
            pendingNeed = nil
            openUnheld(needToken: token)
        }
    }

    /// Caught up and still no session for it: a guarded change no agent made goes to its
    /// folder's page, where it is asked (#531); anything else, to whoever needs you.
    func openUnheld(needToken token: String) {
        if let folder = NeedID.guardedFolder(fromToken: token) {
            sidebarItem = .folder(work.folder(folder)?.key ?? FolderKey(host: .mac, folder: folder))
        } else {
            showTheFirstFolderNeedingYou()
        }
    }

    /// Which conversation a banner is about, from the need it names. The Mac's
    /// `attention/pending` is the truth; this reads the copy the model already holds.
    func agentID(forNeedToken token: String) -> UUID? {
        if let need = work.needs.first(where: { $0.key.token == token }) { return need.value.agentID }
        switch token.split(separator: ":", maxSplits: 1).map(String.init) {
        case let parts where parts.count == 2 && parts[0] == "permission":
            return work.permissions.first { $0.id.uuidString == parts[1] }?.agentID
        case let parts where parts.count == 2 && parts[0] == "elicitation":
            return work.elicitations.first { $0.id.uuidString == parts[1] }?.agentID
        case let parts where parts.count == 2 && parts[0] == "report":
            return UUID(uuidString: String(parts[1].split(separator: ":").first ?? ""))
        case let parts where parts.count == 2 && parts[0] == "guarded":
            // Made by an agent: opened in its chat, where it is asked (Alex, #1045).
            guard let folder = NeedID.guardedFolder(fromToken: token) else { return nil }
            let path = String(token.dropFirst("guarded:\(folder.path):".count))
            return work.folder(folder)?.guardedChanges?.first { $0.path == path }?.askedIn
        default:
            return nil
        }
    }
}
