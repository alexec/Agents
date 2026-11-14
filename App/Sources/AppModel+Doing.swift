import AgentsKitCore
import AppKit
import Foundation
import os

/// Doing: what a person does to an agent.
extension AppModel {
    // MARK: Doing

    /// Where the draft session is made: in a worktree already there when one is chosen,
    /// so the start can use it (research R2). A new worktree has no folder until the
    /// start makes it, so its draft is the folder's and the start lets it go.
    var draftOptionsFolder: URL? {
        if case .existing(let root) = draftWorktree { return root }
        return draftCwd
    }

    /// Choose where the next agent works, and make the draft there if that moved it.
    func chooseWorktree(_ choice: WorktreeChoice?) {
        let before = draftOptionsFolder
        draftWorktree = choice
        if draftOptionsFolder != before, draftRuntimeID != nil {
            Task { await loadDraftOptions() }
        }
    }

    /// Every folder's worktrees on a machine, for its page (#790, #3627). Sizes the
    /// daemon has not measured yet come later, on `worktrees/sized`.
    func loadWorktrees(on host: MachineRef = .mac) async {
        guard let listed = try? await worktreeClient(host).call(DaemonAPI.Method.worktreesAll, DaemonAPI.Empty(),
                                                             returning: [DaemonAPI.FolderWorktrees].self) else { return }
        work.replaceWorktrees(listed, from: host)
    }

    /// The machine a worktree is on: this Mac's own host for This Mac (#1496), else the machine's.
    func worktreeClient(_ host: MachineRef) -> DaemonClient {
        host == .mac ? macClient : client(for: host)
    }

    /// What removing one of a folder's worktrees would lose, or nil when it could
    /// not be asked (and `problem` says why).
    func checkWorktreeRemoval(_ root: URL, in folder: URL, on host: MachineRef = .mac) async -> DaemonAPI.RemovalCheck? {
        do {
            return try await worktreeClient(host).call(DaemonAPI.Method.worktreesCheck,
                                         DaemonAPI.WorktreeRemovalRequest(folder: folder, root: root),
                                         returning: DaemonAPI.RemovalCheck.self)
        } catch {
            problem = describe(error)
            return nil
        }
    }

    /// Remove one of a folder's worktrees. `confirmed` is the person having seen
    /// what would be lost; the daemon checks again either way.
    func removeWorktree(_ root: URL, in folder: URL, on host: MachineRef = .mac, confirmed: Bool) async {
        do {
            _ = try await worktreeClient(host).call(DaemonAPI.Method.worktreesRemove,
                                      DaemonAPI.WorktreeRemovalRequest(folder: folder, root: root,
                                                                       confirmed: confirmed),
                                      returning: DaemonAPI.WorktreeRemoved.self)
        } catch {
            problem = describe(error)
        }
        await loadWorktrees(on: host)
        if draftCwd != nil { await loadDraftWorktrees() }
    }

    /// Delete an idle worktree's build output (#790), and say what it freed; nil when it
    /// could not (and `problem` says why).
    func removeBuildOutput(_ root: URL, in folder: URL, on host: MachineRef = .mac) async -> String? {
        defer { Task { await loadWorktrees(on: host) } }
        do {
            let removed = try await worktreeClient(host).call(DaemonAPI.Method.worktreesRemoveBuildOutput,
                                                DaemonAPI.WorktreeRemovalRequest(folder: folder, root: root),
                                                returning: DaemonAPI.BuildOutputRemoved.self)
            return WorktreeTally.freedWords(removed)
        } catch {
            problem = describe(error)
            return nil
        }
    }

    /// Clean up worktrees (030): a new session in the folder, offered the words.
    func offerCleanUp(in folder: URL, on host: MachineRef = .mac) {
        showFolder(FolderKey(host: host, folder: folder))
        offeredPrompt = PromptOffer(agentID: nil, words: WorktreeTally.cleanUpPrompt)
    }

    /// What an agent changed (035). Asked by the Changes pane on its own triggers —
    /// shown, an edit finished, the turn ended — and never polled.
    func changes(for agentID: UUID) async throws -> ChangesList {
        try await client.call(DaemonAPI.Method.changesList,
                              DaemonAPI.ChangesListRequest(agentID: agentID),
                              returning: ChangesList.self)
    }

    /// One file from `changes(for:)`: its edits, and with `whole` the file as it stands.
    func changeDetail(for agentID: UUID, path: String, whole: Bool = false) async throws -> ChangedFileDetail {
        try await client.call(DaemonAPI.Method.changesFile,
                              DaemonAPI.ChangesFileRequest(agentID: agentID, path: path, whole: whole),
                              returning: ChangedFileDetail.self)
    }

    /// What the draft folder's repository has. Asked once each time the folder
    /// changes or an agent starts, never polled; an answer for a folder since left is
    /// dropped.
    func loadDraftWorktrees() async {
        draftWorktreesGeneration += 1
        let generation = draftWorktreesGeneration
        guard let folder = draftCwd else { return }
        // Each of the form's calls with a deadline (#1096): a reply lost on the way from a
        // server is a failure the form asks again for, not a wait for ever.
        let answer = (try? await draftHostClient.callWithin(StartPageAsks.patience(for: DaemonAPI.Method.worktreesList),
                                                            DaemonAPI.Method.worktreesList,
                                                            DaemonAPI.WorktreesListRequest(folder: folder),
                                                            returning: DaemonAPI.WorktreesListResponse.self))
            ?? .notARepository
        guard generation == draftWorktreesGeneration else { return }
        draftWorktrees = answer
        // A worktree chosen before the answer came, as a view's start does (#834), is no
        // choice in a folder that has none: the chooser is hidden, so it could not be undone.
        if !answer.isRepository { draftWorktree = nil }
    }

    /// The personas the draft folder offers (#760). A host too old to know the method
    /// offers none, and the choice is not drawn.
    func loadDraftPersonas() async {
        guard let folder = draftCwd else { return }
        let listed = (try? await draftHostClient.callWithin(StartPageAsks.patience(for: DaemonAPI.Method.personasList),
                                                            DaemonAPI.Method.personasList,
                                                            DaemonAPI.PersonasListRequest(folder: folder),
                                                            returning: [Persona].self)) ?? []
        guard folder == draftCwd else { return }
        draftPersonas = listed
        if let draftPersona, !listed.contains(where: { $0.id == draftPersona && $0.problem == nil }) {
            self.draftPersona = nil
        }
        draftPromptChanged(draftPromptWords)
    }

    /// The draft's prompt as it is typed (#4559): while the pick is live, the persona its words
    /// name is picked as a hand pick is, and none when no word matches.
    func draftPromptChanged(_ text: String) {
        draftPromptWords = text
        guard draftPersonaAuto else { return }
        let pick = Persona.autoPick(text, among: draftPersonas)
        draftAutoPick = pick
        if pick?.persona.id != draftPersona { choosePersona(pick?.persona, auto: true) }
    }

    func agentConfigEditorFiles(on host: MachineRef, folder: URL?, kind: DaemonAPI.AgentConfigEditorKind)
        async -> [DaemonAPI.AgentConfigEditorFile]? {
        let request = DaemonAPI.AgentConfigEditorRequest(folder: folder, kind: kind)
        return try? await client(for: host).call(DaemonAPI.Method.agentConfigEditorFiles, request,
                                                 returning: [DaemonAPI.AgentConfigEditorFile].self)
    }

    func saveAgentConfigEditorFile(on host: MachineRef, folder: URL?, kind: DaemonAPI.AgentConfigEditorKind,
                                   path: String, content: String, delete: Bool) async -> String? {
        let request = DaemonAPI.AgentConfigEditorSaveRequest(folder: folder, kind: kind, path: path,
                                                               content: content, delete: delete)
        do {
            try await client(for: host).call(DaemonAPI.Method.agentConfigEditorSave, request)
            await refreshWorkflows()
            return nil
        } catch { return describe(error) }
    }

    /// Pick a kind of session (#760): every setting it names is set, and every one it
    /// leaves out stays as the form has it. Nil picks none, and changes nothing else. A
    /// pick by hand sticks for the draft (#4559): typing no longer moves it.
    func choosePersona(_ persona: Persona?, auto: Bool = false) {
        if !auto { draftPersonaAuto = false }
        draftPersona = persona?.id
        pendingPersona = nil
        guard let persona else { return }
        if let runtimeID = persona.settings.runtimeID, runtimeID != draftRuntimeID,
           availableRuntimes.contains(where: { $0.runtime.id == runtimeID }) {
            draftRuntimeID = runtimeID
            pendingPersona = persona
            Task { await loadDraftOptions() }
            return
        }
        if draftOptions.isEmpty {
            pendingPersona = persona
        } else {
            draftChosen.merge(persona.choices(against: draftOptions)) { _, new in new }
        }
    }

    /// What the open agent's folder has, for the Worktree choice on its page (053).
    func loadAgentWorktrees(of agent: Agent) async {
        let folder = agent.folderPath
        let answer = (try? await client(forAgent: agent.id).call(DaemonAPI.Method.worktreesList,
                                                                DaemonAPI.WorktreesListRequest(folder: folder),
                                                                returning: DaemonAPI.WorktreesListResponse.self))
            ?? .notARepository
        agentWorktrees[folder] = answer
    }

    /// Move an agent, or with no target take back the move that is waiting (053). Made
    /// at once when it is between turns; otherwise when its turn ends.
    ///
    /// Drawn at once as the move that waits (#4814): the Worktree choice shows it chosen
    /// before the host answers, and goes back to where it was when the move is refused.
    func move(_ agent: Agent, to target: MoveTarget?) async {
        moveProblems[agent.id] = nil
        let write = AgentWrite.move(target)
        let pending = work.beginWrite(write, on: agent.id)
        do {
            let answer = try await client(forAgent: agent.id).call(DaemonAPI.Method.agentsMove,
                                                                   DaemonAPI.MoveRequest(agentID: agent.id, target: target),
                                                                   returning: DaemonAPI.MoveAnswer.self)
            // Made now, or nothing to do: the host's record says where it is.
            work.settleWrite(pending, on: agent.id, failed: false, done: answer.when != .afterTurn)
            if var moved = answer.agent, answer.when == .now {
                moved.host = agent.host
                work.upsert(moved)
            }
        } catch let error as JSONRPCError {
            work.settleWrite(pending, on: agent.id, failed: true)
            moveProblems[agent.id] = write.failure(error.message)
        } catch {
            work.settleWrite(pending, on: agent.id, failed: true)
            moveProblems[agent.id] = write.failure(error.localizedDescription)
        }
        await loadAgentWorktrees(of: agent)
    }

    /// A session has to exist before its options do, so choosing a folder and a
    /// runtime starts one. It is kept and used by the start that follows.
    func loadDraftOptions() async {
        guard let runtimeID = draftRuntimeID, let cwd = draftOptionsFolder else { return }
        // Auto has no runtime yet, so no options of its own: what it would pick (#2658).
        if runtimeID == LevelWords.autoID {
            draftOptionsGeneration += 1
            draftOptions = []
            draftCommands = []
            draftChosen = [:]
            draftOptionsFailure = nil
            isLoadingDraftOptions = false
            letGo(draft: draftID)
            draftID = nil
            await refreshDraftAutoPreview()
            return
        }
        draftOptionsGeneration += 1
        let generation = draftOptionsGeneration
        isLoadingDraftOptions = true
        draftOptionsFailure = nil
        draftOptions = []
        draftCommands = []
        draftChosen = [:]
        letGo(draft: draftID)
        draftID = nil
        do {
            let response = try await draftHostClient.callWithin(StartPageAsks.patience(for: DaemonAPI.Method.agentsOptions),
                                                                DaemonAPI.Method.agentsOptions,
                                                                DaemonAPI.OptionsRequest(runtimeID: runtimeID, cwd: cwd,
                                                                                         mcpServers: draftServers),
                                                                returning: DaemonAPI.OptionsResponse.self)
            // An answer for a folder or runtime the user has since moved away from is
            // not an answer to the question now being asked — and its runtime is one
            // nobody will talk to.
            guard generation == draftOptionsGeneration else { letGo(draft: response.draftID); return }
            draftID = response.draftID
            show(options: response.options, commands: response.commands, opening: true)
        } catch {
            guard generation == draftOptionsGeneration else { return }
            // Said in the row rather than only in the banner, because the row is where
            // the person is looking and where the retry lives.
            draftOptionsFailure = describe(error)
        }
        if generation == draftOptionsGeneration { isLoadingDraftOptions = false }
    }

    /// A draft this window has replaced is a runtime nobody will talk to. Not waited
    /// on, and a daemon too old to know the method has nothing to be told (029).
    func letGo(draft: UUID?) {
        guard let draft else { return }
        Task {
            _ = try? await draftHostClient.call(DaemonAPI.Method.agentsDiscardDraft,
                                       DaemonAPI.DiscardDraftRequest(draftID: draft))
        }
    }

    /// Draw the form.
    ///
    /// The first answer may be what the runtime offered last time, with what it
    /// actually offers arriving a few seconds later, so this runs more than once for
    /// one draft and keeps every choice already made that is still on offer.
    func show(options: [ConfigOption], commands: [SlashCommand], opening: Bool) {
        draftOptions = PromptControlsState.drawable(agentOptions: nil, draftOptions: options)
        draftCommands = commands
        for option in draftOptions {
            // A choice already made stands, as long as it is still one of the choices.
            if let chosen = draftChosen[option.id],
               option.isBoolean || (option.options ?? []).contains(where: { $0.value == chosen }) {
                continue
            }
            draftChosen[option.id] = option.currentValue
        }
        // Options that have gone are not choices anybody can unmake.
        let offered = Set(draftOptions.map(\.id))
        draftChosen = draftChosen.filter { offered.contains($0.key) }
        // The mode you chose last time for this runtime, if it still offers it.
        // Seeding the draft is enough: `startDraft` sends these as `StartOptions`
        // and the daemon applies each one to the session before the first prompt.
        //
        // What the control opens on, so only on the first draw: a correction arriving
        // behind a form drawn from memory must not undo a mode chosen since.
        if opening, let runtimeID = draftRuntimeID,
           let mode = ModeMemory.modeOption(in: draftOptions) {
            draftChosen[mode.id] = ModeMemory.startingValue(
                remembered: rememberedMode(for: runtimeID), for: mode)
        }
        // The values chosen in the shared words (#2658), kept from the runtime before, over
        // the mode remembered: the form says the same words on every runtime.
        if opening {
            applyDraftLevel(.model)
            applyDraftLevel(.permission)
        }
        // Over the mode remembered, because the persona was picked after it (#760).
        if let persona = pendingPersona, !draftOptions.isEmpty {
            draftChosen.merge(persona.choices(against: draftOptions)) { _, new in new }
            pendingPersona = nil
        }
    }

    /// The runtime starting behind a form drawn from memory has answered at last, and
    /// either offers something else or will not start at all.
    func settleDraft(_ notification: DaemonAPI.DraftOptionsNotification) {
        guard notification.draftID == draftID else { return }
        if let failure = notification.failure {
            // Said in the row rather than the banner, the same as a form that failed to
            // load, because the row is where the person is looking and where the retry
            // lives. The controls go with it: they were what this runtime offered last
            // time, and there is no runtime this time.
            draftOptionsFailure = failure
            draftOptions = []
            draftCommands = []
            draftChosen = [:]
            draftID = nil
            return
        }
        show(options: notification.options, commands: notification.commands, opening: false)
    }

    /// Whether the agent was started, so the prompt bar can give back what it sent
    /// when it was not.
    @discardableResult
    /// `voice`: started from voice mode (#2375), so the first reply is short and fit to be
    /// heard; `started` is told the new agent's id.
    func startDraft(prompt: String, attachments: [Attachment] = [], labels: [String] = [],
                    voice: Bool = false, started: (UUID) -> Void = { _ in }) async -> Bool {
        guard !isStarting, let runtimeID = draftRuntimeID, let cwd = draftCwd else { return false }
        isStarting = true
        defer { isStarting = false }
        let request = DaemonAPI.StartRequest(runtimeID: runtimeID,
                                             cwd: cwd,
                                             prompt: prompt,
                                             attachments: attachments,
                                             startOptions: StartOptions(values: draftChosen),
                                             draftID: draftID,
                                             additionalDirectories: draftFolders,
                                             mcpServers: draftServers,
                                             worktree: draftWorktree,
                                             sandbox: draftSandbox, labels: labels, persona: draftPersona,
                                             accountID: isAutoDraft ? nil : draftAccountChoices?.sent(draftAccountID),
                                             voice: voice ? true : nil,
                                             levels: Levels(model: draftLevels.model, permission: draftLevels.permission,
                                                            permissionRequests: isAutoDraft ? nil : draftClientPermission))
        // A stopped workspace that starts when used: kept, and shown under this prompt (#691 US3).
        if draftHost != .mac, hosts.isOffline(draftHost), startsWhenUsed(draftHost) {
            var kept = request
            kept.draftID = nil
            kept.requestID = UUID()
            guard let said = await keepThroughControl(draftHost, DaemonAPI.Method.agentsStart, kept) else { return false }
            keptStartsShown.insert(said.id)
            return true
        }
        do {
            let id = try await draftHostClient.call(DaemonAPI.Method.agentsStart, request, returning: UUID.self)
            started(id)
            draftID = nil
            // The next draft starts live again (#4559, #4721).
            draftPersonaAuto = true
            draftPromptChanged("")
            // The last folder used is the one a session was started in, from any window (#2160).
            rememberNewSessionFolder(FolderKey(host: draftHost, folder: cwd))
            // Back to the folder, and the list fetched again: the start may
            // have made a worktree, and it has put an agent in one.
            draftWorktree = nil
            Task { await loadDraftWorktrees() }
            if draftHost == .mac {
                await refreshAgents()
                await refreshFolders()
            } else {
                await refreshServer(draftHost)
            }
            // Gone to, as the phone does: what you just asked for is what you want to
            // see start. Once the list has it, so the chat opens on a row that is there.
            // Started in a folder's own window, it opens there (#1089).
            if let window = composingWindow.flatMap({ folderWindows[$0] }) {
                window.show(started: id)
            } else {
                justStarted = id
                selection = id
            }
            draftSandboxRefusal = nil
            draftAutoRefusal = nil
            draftClientPermission = nil
            return true
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.autoNoRuntime {
            // No runtime Auto may use can take it (FR-011): said over the prompt, which keeps it.
            draftAutoRefusal = error.message
            return false
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.kept {
            // Kept until its stopped workspace is up (#691 US3): shown under this prompt, and
            // the agent it makes opens once the host is up.
            if let kept = noteKept(error) { keptStartsShown.insert(kept.id) }
            draftID = nil
            return true
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.sandboxWillNotStart {
            // Said over the prompt, which keeps what was typed, with the way on (064).
            draftSandboxRefusal = try? error.data?.decode(DaemonAPI.SandboxWillNotStart.self)
            if draftSandboxRefusal == nil { fail(error, on: draftHost) }
            return false
        } catch {
            fail(error, on: draftHost)
            return false
        }
    }

    /// Sent now if the agent is free, and queued by the daemon if it is not. Either
    /// way this is the same call: whether there is room for it is not the window's
    /// question to answer.
    @discardableResult
    /// `voice`: sent from voice mode (#2322), so the reply is short and fit to be heard.
    func send(_ text: String, attachments: [Attachment] = [], to agentID: UUID? = nil, voice: Bool = false) async -> Bool {
        // In the chat at once, as the person's bubble, until the host's entry lands (#4814).
        let target = agentID ?? selection
        let drawn = target.flatMap { work.beginSending(text, to: $0) }
        let sent = await deliver(text, attachments: attachments, to: agentID, voice: voice)
        if let target { work.endSending(drawn, to: target, sent: sent) }
        return sent
    }

    func deliver(_ text: String, attachments: [Attachment], to agentID: UUID?, voice: Bool) async -> Bool {
        // The main window's chat, or the one in a window of its own that sent it (#826).
        guard let selection = agentID ?? selection, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let host = host(ofAgent: selection)
        // A stopped workspace that starts when used: kept by the control plane (#691 US3).
        if host != .mac, hosts.isOffline(host), startsWhenUsed(host) {
            guard attachments.isEmpty else {
                problem = "Attachments can’t wait for \(hosts.label(host)) to start. Send the words alone, or start it first."
                return false
            }
            return await keepThroughControl(host, DaemonAPI.Method.agentsPrompt,
                                            DaemonAPI.PromptRequest(agentID: selection, text: text, sendID: UUID(), voice: voice ? true : nil)) != nil
        }
        if host != .mac {
            guard let carried = await carry(attachments, to: host, for: selection) else { return false }
            let sendID = UUID()
            return await sendToServer(host) { client in
                try await client.call(DaemonAPI.Method.agentsPrompt,
                                      DaemonAPI.PromptRequest(agentID: selection, text: text,
                                                              attachments: carried, sendID: sendID,
                                                              voice: voice ? true : nil))
            }
        }
        return await attempt {
            do {
                try await self.client(forAgent: selection).call(DaemonAPI.Method.agentsPrompt,
                                           DaemonAPI.PromptRequest(agentID: selection, text: text,
                                                                   attachments: attachments,
                                                                   voice: voice ? true : nil))
            } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.folderGone {
                // The folder's strip says so, with the ways on, carrying what was typed (#119, #5034).
                self.folderGone = FolderGoneAsk(agentID: selection, message: error.message,
                                                text: text, attachments: attachments)
                throw SaidAlready()
            }
        }
    }
}
