import AgentsKitCore
import Foundation
import Observation
import SwiftUI
import UIKit

/// The remote's state, part of `RemoteModel` (#5383): see `RemoteModel.swift`.
extension RemoteModel {
    // MARK: Secrets for one session (#3548, #4032), on the Mac's host

    func sessionSecrets() async -> SessionSecrets? {
        try? await client.call(DaemonAPI.Method.secretsSessionList, DaemonAPI.Empty(), returning: SessionSecrets.self)
    }

    func setSessionSecret(_ request: SessionSecretSetRequest) async -> Result<SessionSecrets, Error> {
        do {
            return .success(try await client.call(DaemonAPI.Method.secretsSessionSet, request, returning: SessionSecrets.self))
        } catch {
            return .failure(error)
        }
    }

    var sessionHostAsksBeforeUse: Bool { host(.mac, has: Capability.hostSecretApproval1) }

    func setSessionSecretAsksBeforeUse(_ secret: SessionSecret, _ on: Bool) async -> Result<SessionSecrets?, Error> {
        do {
            _ = try await client.call(DaemonAPI.Method.secretsSetNeedsApproval,
                                      SecretNeedsApprovalRequest(name: secret.name, agentID: secret.agentID, needsApproval: on),
                                      returning: DaemonAPI.Empty.self)
            return .success(await sessionSecrets())
        } catch {
            return .failure(error)
        }
    }

    /// Settings ▸ You ▸ Secrets ▸ On This Machine (#5122): what agents saved on the Mac's host.
    func localSecrets() async -> LocalSecrets? {
        try? await client.call(DaemonAPI.Method.secretsLocalList, DaemonAPI.Empty(), returning: LocalSecrets.self)
    }

    func setLocalSecretAsksBeforeUse(_ secret: LocalSecret, _ on: Bool) async -> Result<LocalSecrets?, Error> {
        do {
            _ = try await client.call(DaemonAPI.Method.secretsSetNeedsApproval,
                                      SecretNeedsApprovalRequest(name: secret.name, needsApproval: on),
                                      returning: DaemonAPI.Empty.self)
            return .success(await localSecrets())
        } catch {
            return .failure(error)
        }
    }

    /// Take a session's secret out now: its agent is told it expired.
    func removeSessionSecret(_ secret: SessionSecret) async -> SessionSecrets? {
        do {
            return try await client.call(DaemonAPI.Method.secretsSessionRemove,
                                         SessionSecretRemoveRequest(agentID: secret.agentID, name: secret.name),
                                         returning: SessionSecrets.self)
        } catch {
            problem = sentence(for: error)
            return nil
        }
    }

    /// The Mac's sessions that can take a secret for one session: not archived, latest first.
    var sessionsForSecrets: [Agent] {
        work.agents.filter { $0.host == .mac && $0.state != .archived }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    /// The daily summary's saved pages (#3721), from the Mac's host.
    func refreshSummaryPages() async {
        summaryPages = (try? await client.call(DaemonAPI.Method.summariesList, DaemonAPI.Empty(),
                                               returning: [SummaryPage].self)) ?? []
    }

    /// The Multiplier (#4116), from the Mac's host, as the window asks it: on each catch-up
    /// and each time the page opens, then heard on `multiplier/changed`. With a control plane
    /// that host counts all the person's machines (#3903). A host too old to know the method
    /// leaves it nil, and the page says `— ×`.
    func refreshMultiplier() async {
        guard let multiplier = try? await client.call(DaemonAPI.Method.multiplierState, DaemonAPI.Empty(),
                                                      returning: DaemonAPI.Multiplier.self) else { return }
        work.replaceMultiplier(multiplier)
    }

    /// The PRs that landed (#4758), for the Velocity page: the Mac's host's lineage alone, as
    /// the window asks it (#4597). Nil when the host does not know the method, and the page
    /// keeps its progress wheel.
    func velocityHistory() async -> VelocityHistory? {
        guard let history = try? await client.call(DaemonAPI.Method.velocityHistory, Optional<String>.none,
                                                   returning: VelocityHistory.self) else { return nil }
        return .merged([history])
    }

    /// The achievements (#984), for the Multiplier page's badges (#4116), from the Mac's host;
    /// then heard on `achievements/changed`.
    func refreshAchievements() async {
        guard let achievements = try? await client.call(DaemonAPI.Method.achievementsState, DaemonAPI.Empty(),
                                                        returning: Achievements.self) else { return }
        work.replaceAchievements(achievements)
    }

    /// The agents with a turn starting or running, for the Multiplier page's "agents now".
    var agentsWorking: Int {
        work.agents.count { $0.state == .starting || $0.state == .running }
    }

    /// One saved page of the daily summary (#3721); reading the newest marks it read.
    func readSummaryPage(_ name: String) async -> SummaryPageText? {
        try? await client.call(DaemonAPI.Method.summariesRead, SummaryReadRequest(name: name),
                               returning: SummaryPageText.self)
    }

    /// The person chose Off or Summary, or a time, for the daily summary (#3351). Nil when it
    /// was set; else why not, and the control goes back to what it was.
    func setDailySummarySettings(_ settings: DailySummarySettings) async -> String? {
        let before = dailySummarySettings
        dailySummarySettings = settings
        do {
            dailySummarySettings = try await client.call(DaemonAPI.Method.dailySummarySetSettings, settings,
                                                         returning: DailySummarySettings.self)
            return nil
        } catch {
            dailySummarySettings = before
            return sentence(for: error)
        }
    }

    func refreshAuto() async {
        if let m = try? await client.call(DaemonAPI.Method.autoMappings, DaemonAPI.Empty(), returning: AutoMappings.self) {
            autoMappings = m
        }
    }

    func choose(_ value: JSONValue, for optionID: String) {
        startChosen[optionID] = value
    }

    /// A runtime is started behind the form so its choices are real ones; the start
    /// that follows uses it. Drawn at once from what it offered this page last time
    /// (#1171), then from the host's answer, and put right by `agents/draftOptions` if
    /// it has moved. A Send before the answer starts without the draft, with the
    /// choices on the page.
    func loadStartChoices() async {
        guard let folder = startOptionsFolder else { return }
        // The levels last chosen on any client, not Ask again each time (#3798).
        startLevels = DisplayPreference.keptLevels(in: displayMirror.preferences, default: startLevels)
        // Auto has no runtime yet, so no options of its own: what it would pick (#2658).
        if startRuntimeID == LevelWords.autoID {
            startGeneration += 1
            discardStartDraft()
            startOptions = []
            startChosen = [:]
            startChoicesState = .ready
            startAsks.answered(.choices)
            await refreshStartAutoPreview()
            return
        }
        guard let runtimeID = startRuntimeID else {
            // Not "asking": there is nobody to ask.
            let host = startHost == .mac ? "the Mac" : hostName(startHost)
            if startRuntimes.isEmpty, let failure = runtimesFailure[startHost] {
                startChoicesState = .failed("Could not list the runtimes on \(host). \(failure)")
                return
            }
            startChoicesState = .failed(startRuntimes.isEmpty
                ? "No runtimes are set up on \(host). Set one up there to start an agent."
                : "None of \(host)'s runtimes can start right now.")
            return
        }
        startGeneration += 1
        let generation = startGeneration
        startAsks.asking(.choices)
        discardStartDraft()
        let host = startHost
        startChosen = displayMirror.preferences[DisplayPreference.startChoices]?.objectValue?[runtimeID]?.objectValue ?? [:]
        let remembered = startMemory.options(for: runtimeID, on: host)
        if let remembered {
            showStart(remembered, opening: true, answered: false)
        } else {
            startOptions = []
            startChoicesState = .loading
        }
        do {
            // Made on the folder's own host, where the agent will start (#240).
            let request = DaemonAPI.OptionsRequest(runtimeID: runtimeID, cwd: folder)
            let response = try await askForStart(DaemonAPI.Method.agentsOptions, request,
                                                 returning: DaemonAPI.OptionsResponse.self)
            guard generation == startGeneration else { discard(draft: response.draftID, on: host); return }
            startDraftID = response.draftID
            startDraftHost = host
            startMemory.remember(response.options, for: runtimeID, on: host)
            // Over choices made from memory meanwhile: only the first draw opens.
            showStart(response.options, opening: remembered == nil)
        } catch {
            guard generation == startGeneration else { return }
            startChoicesState = .failed(sentence(for: error))
        }
    }

    /// Draw what the runtime offers, keeping every choice already made that is still
    /// one of the choices.
    ///
    /// On the first draw only, the mode opens on the one last chosen for this runtime
    /// on any device, as the Mac's form does: a correction arriving behind a form drawn
    /// from memory must not undo a mode chosen since.
    ///
    /// `answered` is false for a draw from memory: the host has still to say.
    func showStart(_ options: [ConfigOption], opening: Bool = false, answered: Bool = true) {
        startOptions = PromptControlsState.drawable(agentOptions: nil, draftOptions: options)
        var kept = StartChoicesMemory.kept(startChosen, in: startOptions)
        if opening, let runtimeID = startRuntimeID, let mode = ModeMemory.modeOption(in: startOptions),
           let value = ModeMemory.startingValue(remembered: work.rememberedMode(for: runtimeID), for: mode) {
            kept[mode.id] = value
        }
        // Over the mode remembered, because the persona was picked after it (#760).
        if let persona = pendingStartPersona, !startOptions.isEmpty {
            kept.merge(persona.choices(against: startOptions)) { _, new in new }
            pendingStartPersona = nil
        }
        startChosen = kept
        // The values chosen in the shared words, over the mode remembered (#2658).
        if opening {
            applyStartLevel(.model)
            applyStartLevel(.permission)
        }
        startChoicesState = .ready
        if let openedAt = startOpenedAt {
            startOpenedAt = nil
            note("start: page ready \(answered ? "from the host" : "from memory") in \(ContinuousClock.now - openedAt)")
        }
        if answered { startAsks.answered(.choices) }
    }

    func settleStartDraft(_ notification: DaemonAPI.DraftOptionsNotification) {
        guard notification.draftID == startDraftID else { return }
        if let failure = notification.failure {
            startDraftID = nil
            startOptions = []
            startChosen = [:]
            startChoicesState = .failed(failure)
            startAsks.asking(.choices)
            return
        }
        if let runtimeID = startRuntimeID {
            startMemory.remember(notification.options, for: runtimeID, on: startDraftHost)
        }
        showStart(notification.options)
    }

    func discardStartDraft() {
        guard let startDraftID else { return }
        self.startDraftID = nil
        discard(draft: startDraftID, on: startDraftHost)
    }

    /// Not waited on: the page has moved on, and a Mac too old to know the method has
    /// nothing to be told. To the host the draft was made on (#240).
    func discard(draft: UUID, on host: MachineRef) {
        let target = host == .mac ? client : otherHosts[host] ?? client
        Task { _ = try? await target.call(DaemonAPI.Method.agentsDiscardDraft,
                                          DaemonAPI.DiscardDraftRequest(draftID: draft)) }
    }

    /// Start an agent in the page's folder. Answers whether it started, so the page
    /// keeps what was typed when it did not.
    ///
    /// Refused here, before anything is sent, when the Mac is not answering or the
    /// folder cannot take a new agent. Refused by the Mac, its sentence is shown as it
    /// is. Lost on the way back, nothing is assumed: the start is kept, and settled by
    /// its request id once the Mac is heard from again.
    /// `voice`: said in voice mode, so its replies are spoken, as on the Mac; `started` is
    /// told the new session's id (Alex, 2026-10-29).
    func startAgent(prompt: String, attachments: [Attachment] = [], labels: [String] = [],
                    in folder: FolderKey, page: UUID, voice: Bool = false,
                    started: (UUID) -> Void = { _ in }) async -> Bool {
        let words = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !isStarting else { return false }
        // On screen but not held (#1044): held again, and said, rather than a Send that
        // does nothing.
        guard let folder = startingIn, folder == folder else {
            startPageAppeared(in: folder, page: page)
            startRefusal = "This page was opened again. Check its choices, then send."
            return false
        }
        if let refusal = startRefusalBeforeSending(in: folder) {
            startRefusal = refusal
            return false
        }
        guard let runtimeID = startRuntimeID else {
            startRefusal = "Choose a runtime to start."
            return false
        }
        // Before sending, and in the Mac's words: a runtime that will not take what is
        // attached would refuse the whole prompt after the agent had started.
        let capabilities = promptCapabilities(for: runtimeID)
        let runtime = promptRuntimeName(for: runtimeID)
        if let refused = attachments.first(where: { PhoneAttachment.refusal(for: $0, from: capabilities) != nil }),
           let reason = PhoneAttachment.refusal(for: refused, from: capabilities, runtime: runtime) {
            startRefusal = "\(refused.displayName): \(reason)."
            return false
        }
        if let tooMuch = PhoneAttachment.totalRefusal(attachments) {
            startRefusal = tooMuch
            return false
        }
        // The unsettled start's id only for the same folder: sent again there, the Mac
        // answers with the agent it made if it made one. Anywhere else it is a new
        // start, and reusing the id would be answered with the other folder's agent.
        let retrying = unsettledStart?.cwd == folder.folder && unsettledStartOn == folder.host
            ? unsettledStart?.requestID : nil
        let request = DaemonAPI.StartRequest(
            runtimeID: runtimeID, cwd: folder.folder, prompt: words, attachments: attachments,
            startOptions: StartOptions(values: startChosen), draftID: startDraftID,
            additionalDirectories: startFolders, worktree: startWorktree, requestID: retrying ?? UUID(), sandbox: startSandbox,
            labels: labels, persona: startPersona,
            accountID: isAutoStart ? nil : startAccountChoices?.sent(startAccountID),
            voice: voice ? true : nil,
            levels: Levels(model: startLevels.model, permission: startLevels.permission,
                           permissionRequests: isAutoStart ? nil : startClientPermission))
        startingPage = page
        defer { startingPage = nil }
        return await send(start: request, on: folder.host, told: started)
    }

    func setLabels(on id: UUID, add: [String] = [], remove: [String] = [], offeringUndo: Bool = true) async -> Bool {
        let undo = offeringUndo ? work.agent(id).flatMap { SessionUndo.labels($0, add: add, remove: remove) } : nil
        let sent = await optimistic(.labels(add: add, remove: remove), on: id) { await sendLabels(on: id, add: add, remove: remove) }
        if sent { offer(undo) }
        return sent
    }

    func sendLabels(on id: UUID, add: [String], remove: [String]) async -> Bool {
        do {
            let request = DaemonAPI.SetLabelsRequest(agentID: id, add: add, remove: remove)
            let agent: Agent = try await client(for: request).call(DaemonAPI.Method.agentsSetLabels, request,
                                                                   returning: Agent.self)
            work.upsert(agent)
            await loadLabelVocabulary(in: agent.folderPath)
            return true
        } catch {
            problem = (error as? JSONRPCError)?.message ?? "That label change did not reach your Mac."
            return false
        }
    }

    func labelSuggestions(in folder: URL) -> [String] {
        labelVocabularies[Folder.standardize(folder)] ?? []
    }

    func loadLabelVocabulary(in folder: URL) async {
        let folder = Folder.standardize(folder)
        let request = DaemonAPI.LabelVocabularyRequest(folder: folder)
        guard let values = try? await client(for: request).call(DaemonAPI.Method.agentsLabelVocabulary, request,
                                                                returning: [String].self) else { return }
        labelVocabularies[folder] = values
    }

    func send(start request: DaemonAPI.StartRequest, on host: MachineRef,
                      told: (UUID) -> Void = { _ in }) async -> Bool {
        isStarting = true
        defer { isStarting = false }
        startRefusal = nil
        // Its Live Activity begins once the Mac says which session it made (#1657).
        if let requestID = request.requestID { liveActivities.askedToStart(requestID) }
        // A stopped workspace that starts when used: kept, and shown on this page until the
        // agent it makes opens (#691 US3, layouts.md L6a).
        if host != .mac, isStale(on: host), startsWhenUsed(host) {
            var kept = request
            kept.draftID = nil
            guard let said = await keepThroughControl(host, DaemonAPI.Method.agentsStart, kept) else { return false }
            keptStartsShown.insert(said.id)
            StartDraftKeeper.shared.clear(in: FolderKey(host: host, folder: request.cwd), folders: folders)
            return true
        }
        unsettledStart = request
        unsettledStartOn = host
        do {
            let id = try await sendOnce(DaemonAPI.Method.agentsStart, request, on: host).decode(UUID.self)
            // Taken by the start. One that answered after the Send (#1171) is let go as the
            // page closes.
            if startDraftID == request.draftID { startDraftID = nil }
            told(id)
            await started(id, in: FolderKey(host: host, folder: request.cwd))
            return true
        } catch let refused as JSONRPCError {
            // The Mac said no, so nothing was started under this id and a later
            // Send is a fresh start.
            unsettledStart = nil
            startRefusal = refused.message
            // Its sandbox would not start (064): what it said, and the way on.
            if refused.code == DaemonAPI.Failure.sandboxWillNotStart,
               let why = try? refused.data?.decode(DaemonAPI.SandboxWillNotStart.self) {
                startRefusal = refused.message + " " + (why.detail.split(separator: "\n").first.map(String.init) ?? "")
                    + (why.offOffered ? " Set Sandbox to Off to start without it." : "")
            }
            return false
        } catch {
            // Out of patience too (#208): the page is let go, and the start is settled
            // when the host is back, by its `requestID`.
            startRefusal = "\((error as? HostAway).map { hostName($0.host) } ?? "Your Mac") stopped answering before it said whether the agent "
                + "started. This will be checked when it is back."
            return false
        }
    }

    /// - Parameter open: go to it. True when the person is waiting on the page; false
    ///   when a lost answer is settled later, perhaps while they read something else,
    ///   and taking the screen from them would be the surprise.
    func started(_ id: UUID, in key: FolderKey, open: Bool = true) async {
        // The last folder used is the one a session was started in, from any window (#2160).
        rememberNewSessionFolder(key)
        unsettledStart = nil
        startWorktree = nil
        // Only now: a draft is kept until the agent it was typed for exists (FR-017).
        StartDraftKeeper.shared.clear(in: key, folders: folders)
        guard open else { return }
        await loadWholeAgent(id)
        // The page that started it goes; one still on screen under it is opened again.
        if let startingPage { startedPages.insert(startingPage) }
        startPage.release()
        startPageMoved(afresh: true)
        // Started in a folder's own scene: it opens there (#1089).
        if let scene = composingScene.flatMap({ folderScenes[$0] }), scene.key == key {
            scene.pick = .session(id)
            return
        }
        selectedKey = key
        openWorkflow = nil
        // In the start page's place, which is the detail's own: no sheet to wait out (#366).
        selection = id
    }

    /// A start whose answer was lost: find the agent it made, or send it again with the
    /// same id, which the Mac answers with that agent if it did make one.
    func settleUnsettledStart() async {
        guard let request = unsettledStart, let requestID = request.requestID else { return }
        let key = FolderKey(host: unsettledStartOn, folder: request.cwd)
        if let made = work.agents.first(where: { $0.startRequestID == requestID }) {
            await started(made.id, in: key, open: startingIn == key)
            return
        }
        guard startingIn == key else { return }
        _ = await send(start: request, on: key.host)
    }

    func startRefusalBeforeSending(in folder: FolderKey) -> String? {
        let host = folder.host
        if isStale(on: host), !(host != .mac && startsWhenUsed(host)) { return notAnswering(host, "nothing was started.") }
        guard let summary = work.folder(folder) else { return nil }
        if summary.folder.isArchived { return "This folder was archived on the Mac, so nothing was started." }
        if !summary.exists { return "This folder is not on the Mac any more, so nothing was started." }
        if let runtime = startRuntime, let reason = runtime.unavailableReason {
            return "\(runtime.runtime.name) cannot start: \(reason)"
        }
        return nil
    }

    func sentence(for error: any Error) -> String {
        (error as? JSONRPCError).map(OlderPeer.controlRefusal) ?? "Your Mac did not answer."
    }

    /// A refusal in the Remote's words.
    func refusal(_ error: any Error) -> String { sentence(for: error) }
}
