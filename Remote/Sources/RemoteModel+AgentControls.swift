import AgentsKitCore
import Foundation
import Observation
import SwiftUI
import UIKit

/// The remote's state, part of `RemoteModel` (#5383): see `RemoteModel.swift`.
extension RemoteModel {
    // MARK: The agent's own controls (033)

    /// What an option control should read. The same bookkeeping as the Mac's, in the
    /// kit, so a choice made here shows at once and settles the same way.
    func chosenOption(_ optionID: String, for agent: Agent, advertised: ConfigOption) -> JSONValue? {
        work.chosenOption(optionID, for: agent, advertised: advertised)
    }

    /// Change one of a running agent's options, from the phone. Not `async`, so the
    /// choice is on the control as the menu closes.
    func setOption(agentID: UUID, optionID: String, value: JSONValue) {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be changed."
            return
        }
        let sequence = work.beginOption(agentID: agentID, optionID: optionID, value: value)
        Task {
            do {
                let request = DaemonAPI.SetOptionRequest(agentID: agentID, optionID: optionID, value: value)
                try await client(for: request).call(DaemonAPI.Method.agentsSetOption, request)
            } catch {
                problem = (error as? JSONRPCError)?.message ?? "That did not reach your Mac."
            }
            work.settleOption(agentID: agentID, optionID: optionID, sequence: sequence)
        }
    }

    /// What the controls row shows for an agent that exists. Its options came with it,
    /// so there is nothing to load.
    func controlsState(for agent: Agent) -> PromptControlsState {
        PromptControlsState.resolve(agentOptions: agent.advertisedOptions,
                                    draftOptions: [],
                                    hasFolder: true,
                                    hasRuntime: true,
                                    runtimeName: PromptWords.runtimeName(agent.runtimeID),
                                    isLoading: false,
                                    failure: nil)
    }

    /// Let this one agent carry on past its limit: one more step of its ceiling, the
    /// same step the Mac takes. No other agent is changed.
    func letThisAgentGoOn(_ agent: Agent) async {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be changed."
            return
        }
        do {
            let request = agent.goOnRequest(under: costLimits)
            let changed = try await client(for: request).call(DaemonAPI.Method.agentsSetCeiling, request,
                                                              returning: Agent.self)
            work.upsert(changed)
        } catch {
            problem = "That did not reach your Mac."
        }
    }

    /// Files under the agent's folders for what follows an `@`, found on the Mac.
    /// Empty when the Mac is not answering: an empty list is not a problem to show.
    func mentions(_ term: String, for agentID: UUID) async -> [FileMention] {
        guard !isStale, !term.isEmpty else { return [] }
        let found = try? await client.call(DaemonAPI.Method.filesMention,
                                           DaemonAPI.FileMentionRequest(agentID: agentID, term: term),
                                           returning: [DaemonAPI.FileMentionDTO].self)
        return (found ?? []).map(\.mention)
    }

    /// Take something back off the queue before it goes (033). The same call the Mac
    /// makes; the row goes on both when the daemon says the agent changed.
    func unqueue(_ prompt: QueuedPrompt, from agentID: UUID) async {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be taken back."
            return
        }
        do {
            let request = DaemonAPI.UnqueueRequest(agentID: agentID, promptID: prompt.id)
            try await client(for: request).call(DaemonAPI.Method.agentsUnqueue, request)
        } catch {
            problem = "That did not reach your Mac."
        }
    }

    /// New words for a queued prompt, in its place in the queue (#1552). When it was sent or
    /// taken back first, the words go into the prompt bar, so nothing typed is lost.
    func editQueued(_ prompt: QueuedPrompt, text: String, of agentID: UUID) async {
        guard !isStale else {
            offeredPrompt = PromptOffer(agentID: agentID, words: text)
            problem = "Your Mac is not answering, so that could not be changed. Your words are in the prompt bar."
            return
        }
        do {
            let request = DaemonAPI.EditQueuedRequest(agentID: agentID, promptID: prompt.id, text: text)
            let result = try await client(for: request).call(DaemonAPI.Method.agentsEditQueued, request,
                                                             returning: DaemonAPI.EditQueuedResult.self)
            guard !result.edited else { return }
            offeredPrompt = PromptOffer(agentID: agentID, words: text)
            problem = QueuedPrompt.sentBeforeEdit
        } catch {
            offeredPrompt = PromptOffer(agentID: agentID, words: text)
            problem = "That did not reach your Mac. Your words are in the prompt bar."
        }
    }

    /// Stop one shell an agent left running, and nothing else it is doing (057). The
    /// row goes when the daemon says the agent changed.
    func stopBackground(_ item: BackgroundItem, of agentID: UUID) async {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be stopped."
            return
        }
        do {
            let request = DaemonAPI.StopBackgroundRequest(agentID: agentID, itemID: item.id)
            try await client(for: request).call(DaemonAPI.Method.agentsStopBackground, request)
        } catch {
            problem = "That did not reach your Mac."
        }
    }

    /// Send a queued prompt into the turn that is running, where the runtime takes one.
    /// Once: the row shows it going, and a second tap is not a second send (#87).
    func sendNow(_ prompt: QueuedPrompt, to agentID: UUID) async {
        await act(.sendNow(prompt.id), on: agentID,
                  DaemonAPI.Method.agentsSendNow,
                  DaemonAPI.UnqueueRequest(agentID: agentID, promptID: prompt.id))
    }

    /// Start now (#5156): a queued session started at once, past the running limit, by the
    /// person's tap. The Mac refuses it when the folder's total is full, and says why.
    func startNow(_ agentID: UUID) async {
        await act(.startNow, on: agentID, DaemonAPI.Method.agentsStartNow, DaemonAPI.AgentRequest(agentID: agentID))
    }

    /// Whether Start now is offered on this session: queued by an agent, on a host that has it.
    func canStartNow(_ agent: Agent) -> Bool {
        HelperLimit.canStartNow(agent) && self.agent(agent.id, has: Capability.agentsStartNow1)
    }

    /// What a command an agent ran has printed, as far as this phone heard it.
    func terminalOutput(_ terminalID: String) -> String { work.terminalOutput[terminalID] ?? "" }

    func stop(_ agentID: UUID) async {
        await act(.stop, on: agentID, DaemonAPI.Method.agentsStop, DaemonAPI.AgentStopRequest(agentID: agentID))
    }

    /// Stop a session and every session it started that is running (#835).
    func stopAll(_ agentID: UUID) async {
        for agent in [work.agent(agentID)].compactMap({ $0 }) + work.liveDescendants(of: agentID) where canStop(agent) {
            await stop(agent.id)
        }
    }

    func archive(_ agentID: UUID, andLeave: Bool = false) async {
        guard let undo = await ArchiveActions.archiveWithChildren(agentID, in: work, andLeave: andLeave,
                                                                   archiveOne: archiveOne) else { return }
        // Undo for a few seconds, at the foot of the screen (#1534).
        archiveUndo = undo
        sessionUndo = nil
    }

    /// Undo after Archive (#1534): Unarchive what that Archive put away.
    func undoArchive() async {
        guard let undo = archiveUndo else { return }
        archiveUndo = nil
        for id in undo.agentIDs { await unarchive(id, offeringUndo: false) }
    }

    func dismissArchiveUndo(_ undo: ArchiveUndo) {
        if archiveUndo?.id == undo.id { archiveUndo = nil }
    }

    /// Offer Undo for an action that went.
    func offer(_ undo: SessionUndo?) {
        guard let undo else { return }
        sessionUndo = undo
        archiveUndo = nil
    }

    /// Undo (⌘Z) after Unarchive, Rename, the labels, Mute or Later (#4793): the inverse,
    /// sent with no Undo of its own.
    func undoSessionChange() async {
        guard let undo = sessionUndo else { return }
        sessionUndo = nil
        switch undo.inverse {
        case .archive(let id): await archiveOne(id, andLeave: false)
        case .rename(let id, let title): await rename(id, to: title, offeringUndo: false)
        case .labels(let id, let add, let remove): _ = await setLabels(on: id, add: add, remove: remove, offeringUndo: false)
        case .mute(let id, let muted): await setMuted(id, muted, offeringUndo: false)
        case .bringBack(let request): await undeferRequest(request)
        }
    }

    func dismissSessionUndo(_ undo: SessionUndo) {
        if sessionUndo?.id == undo.id { sessionUndo = nil }
    }

    @discardableResult
    func archiveOne(_ agentID: UUID, andLeave: Bool) async -> Bool {
        let archived = await act(.archive, on: agentID, DaemonAPI.Method.agentsArchive,
                                 DaemonAPI.AgentRequest(agentID: agentID))
        // Not when it failed: the chat stays in front, under the reason why.
        if archived, andLeave {
            if selection == agentID { selection = nil }
            // A folder's own screen or scene goes back to its list (#2090).
            for state in folderScenes.values where state.pick == .session(agentID) { state.pick = nil }
        }
        return archived
    }

    /// **Continue in New** (#999): a session in the same folder that reads this one and
    /// carries on, on the runtime's account for new sessions, and open it.
    @discardableResult
    func continueInNew(_ agentID: UUID, onAuto: Bool = false) async -> Bool {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be sent."
            return false
        }
        do {
            let id = try await sendOnce(DaemonAPI.Method.agentsContinueInNew,
                                        DaemonAPI.ContinueInNewRequest(agentID: agentID, requestID: UUID(),
                                                                       auto: onAuto ? true : nil)).decode(UUID.self)
            await loadWholeAgent(id)
            selection = id
            return true
        } catch let error as JSONRPCError {
            problem = error.message
            return false
        } catch {
            problem = "That did not reach your Mac."
            return false
        }
    }

    /// Continue in the folder (#119): a successor that reads this session and
    /// carries on, with whatever was typed, opened once the Mac has started it.
    @discardableResult
    func continueInFolder(_ agentID: UUID, text: String = "", attachments: [Attachment] = []) async -> Bool {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be sent."
            return false
        }
        let folder = work.agent(agentID).map { FolderKey(host: $0.host, folder: $0.folderPath) }
        do {
            let id = try await sendOnce(DaemonAPI.Method.agentsContinueInFolder,
                                        DaemonAPI.ContinueInFolderRequest(agentID: agentID, text: text,
                                                                           attachments: attachments,
                                                                           requestID: UUID())).decode(UUID.self)
            await loadWholeAgent(id)
            if let folder { selectedKey = folder }
            selection = id
            return true
        } catch let error as JSONRPCError {
            problem = error.message
            return false
        } catch {
            problem = "That did not reach your Mac."
            return false
        }
    }

    /// Recreate the worktree from its branch (#119).
    func recreateWorktree(_ agentID: UUID) async {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be sent."
            return
        }
        do {
            try await sendOnce(DaemonAPI.Method.agentsRecreateWorktree, DaemonAPI.AgentRequest(agentID: agentID))
            await loadWholeAgent(agentID)
        } catch let error as JSONRPCError {
            problem = error.message
        } catch {
            problem = "That did not reach your Mac."
        }
    }

    /// Carry on when the allowance is back, or no longer (#1859).
    func continueWhenBack(_ agentID: UUID) async { await waitForAllowance(agentID, DaemonAPI.Method.agentsContinueWhenBack) }

    func cancelContinue(_ agentID: UUID) async { await waitForAllowance(agentID, DaemonAPI.Method.agentsCancelContinue) }

    /// Pause on touch's two answers (#3004, US3), as on the Mac.
    func resumeDesktopControl(_ agentID: UUID) async { await waitForAllowance(agentID, DaemonAPI.Method.desktopControlResume) }

    func takeOverDesktopControl(_ agentID: UUID) async { await waitForAllowance(agentID, DaemonAPI.Method.desktopControlTakeOver) }

    func waitForAllowance(_ agentID: UUID, _ method: String) async {
        guard !isStale(on: work.agent(agentID)?.host ?? .mac) else {
            problem = "Your Mac is not answering, so that could not be sent."
            return
        }
        do {
            try await sendOnce(method, DaemonAPI.AgentRequest(agentID: agentID))
            await loadWholeAgent(agentID)
        } catch let error as JSONRPCError {
            problem = error.message
        } catch {
            problem = away(error, "that could not be sent.") ?? "That did not reach your Mac."
        }
    }

    /// Branch (#342): a new session that carries the history so far, the original left
    /// alone, as the Mac's row has it. Opened once its host has started it.
    func fork(_ agentID: UUID) async {
        guard !isStale(on: work.agent(agentID)?.host ?? .mac) else {
            problem = "Your Mac is not answering, so that could not be sent."
            return
        }
        let folder = work.agent(agentID).map { FolderKey(host: $0.host, folder: $0.folderPath) }
        do {
            let id = try await sendOnce(DaemonAPI.Method.agentsFork,
                                        DaemonAPI.AgentRequest(agentID: agentID)).decode(UUID.self)
            await loadWholeAgent(id)
            if let folder { selectedKey = folder }
            selection = id
        } catch let error as JSONRPCError {
            problem = error.message
        } catch {
            problem = away(error, "that could not be sent.") ?? "That did not reach your Mac."
        }
    }

    /// The machines `agent` can move to (#3790), as the window's sheet lists them: the Machines
    /// group's others that are online now, This Mac first. Nil when its host cannot move a
    /// session, or is not answering.
    func moveTargets(for agent: Agent) -> [MachineRef]? {
        guard agent.state != .archived, !isStale(agent), host(agent.host, has: Capability.sessionsMove1) else { return nil }
        return machines.filter { $0 != agent.host && !machineOffline($0) }
    }

    /// Moves `agent` to `machine`, into `folder` there, or the folder of its project there when
    /// `folder` is empty (#3790). It answers once its host has checked the move (#4641), and
    /// `move/changed` says how it goes; once that machine has it, a chat open on it follows it
    /// to its folder there. Sent once: a move is not a call to send twice.
    func moveToMachine(_ agent: Agent, machine: MachineRef, folder: String) async throws {
        let folder = folder.trimmingCharacters(in: .whitespaces)
        guard let id = machine == .mac ? controlHome : machine else { throw HostAway(host: machine) }
        let request = DaemonAPI.MoveToMachineRequest(agentID: agent.id, machine: id.rawValue, machineName: machineName(machine),
                                                     folder: folder.isEmpty ? nil : folder)
        let answer = try await client(for: request, on: agent.host)
            .callWhileAnswering(DaemonAPI.Method.agentsMoveToMachine, request, checkingEvery: .seconds(10))
            .decode(DaemonAPI.MoveToMachineAnswer.self)
        let there = FolderKey(host: machine, folder: URL(fileURLWithPath: answer.folder))
        // A host from before #4641 answers once that machine has it, and says nothing more.
        guard host(agent.host, has: Capability.sessionsMoving1) else {
            if selection == agent.id {
                selectedKey = there
                selection = agent.id
            }
            return
        }
        moveFollows[agent.id] = there
    }

    /// The moves `host` is making, for a phone that connects mid-move (#4641). Those that
    /// stopped stay until they are put away.
    func refreshMoves(on host: MachineRef, through link: DaemonClient) async {
        guard self.host(host, has: Capability.sessionsMoving1),
              let running = try? await link.call(DaemonAPI.Method.agentsMoves,
                                                 returning: [DaemonAPI.MoveNotification].self) else { return }
        for move in running { moves[move.agentID] = move }
    }

    /// A `move/changed` from any host: the card's line goes a step further, says why it
    /// stopped, or, once the session is there, goes, and a chat open on it follows it.
    func moveChanged(_ change: DaemonAPI.MoveNotification) {
        guard change.finished else {
            moves[change.agentID] = change
            return
        }
        let follow = moveFollows.removeValue(forKey: change.agentID)
        if change.problem != nil {
            moves[change.agentID] = change
            return
        }
        moves[change.agentID] = nil
        if let follow, selection == change.agentID {
            selectedKey = follow
            selection = change.agentID
        }
    }

    /// Takes a move that stopped off its session's card.
    func putAwayMove(_ agentID: UUID) {
        if moves[agentID]?.finished == true { moves[agentID] = nil }
    }

    /// What the sheet says when a move did not go.
    func moveProblem(_ error: any Error) -> String {
        away(error, "the session could not be moved.") ?? sentence(for: error)
    }

    /// Branch from Here (#1658): a new session from just before one of the person's prompts,
    /// opened as Branch opens one, with that prompt in its bar to change and send. The words
    /// go in as the new session's draft, so its bar has them however it comes on screen.
    /// Undo These Changes on a turn's card (#3437), on the agent's Mac. Thrown errors are
    /// the card's to say.
    func undoTurn(_ turn: UUID, of agentID: UUID, confirmed: Bool) async throws -> DaemonAPI.UndoTurnResult {
        try await sendOnce(DaemonAPI.Method.changesUndoTurn,
                           DaemonAPI.UndoTurnRequest(agentID: agentID, turn: turn, confirmed: confirmed ? true : nil))
            .decode(DaemonAPI.UndoTurnResult.self)
    }

    func branch(from entryID: UUID, of agentID: UUID, text: String) async {
        guard !isStale(on: work.agent(agentID)?.host ?? .mac) else {
            problem = "Your Mac is not answering, so that could not be sent."
            return
        }
        let folder = work.agent(agentID).map { FolderKey(host: $0.host, folder: $0.folderPath) }
        do {
            let id = try await sendOnce(DaemonAPI.Method.agentsBranchFrom,
                                        DaemonAPI.BranchFromRequest(agentID: agentID, entryID: entryID))
                .decode(UUID.self)
            StartDraftKeeper.shared.note(text, [], for: .agent(id))
            await loadWholeAgent(id)
            if let folder { selectedKey = folder }
            selection = id
        } catch let error as JSONRPCError {
            problem = error.message
        } catch {
            problem = away(error, "that could not be sent.") ?? "That did not reach your Mac."
        }
    }

    func unarchive(_ agentID: UUID, offeringUndo: Bool = true) async {
        let undo = offeringUndo ? work.agent(agentID).flatMap(SessionUndo.unarchived) : nil
        let sent = await optimistic(.unarchive, on: agentID) { await act(DaemonAPI.Method.agentsUnarchive, agentID) }
        if sent { offer(undo) }
    }

    /// Rename… from a row's menu or the chat's ···: the field starts on the title it has.
    func askToRename(_ agent: Agent) {
        renameText = agent.title ?? ""
        renaming = agent
    }

    /// The person's title for a session (#751), kept by its host and told to every client.
    /// Empty, the runtime names it again.
    func rename(_ agentID: UUID, to title: String, offeringUndo: Bool = true) async {
        let undo = offeringUndo ? work.agent(agentID).flatMap { SessionUndo.renamed($0, to: title) } : nil
        let sent = await optimistic(.rename(title), on: agentID) {
            let host = work.agent(agentID)?.host ?? .mac
            guard !isStale(on: host) else {
                problem = notAnswering(host, "that could not be sent.")
                return false
            }
            do {
                let request = DaemonAPI.RenameRequest(agentID: agentID, title: title)
                try await client(for: request).call(DaemonAPI.Method.agentsRename, request)
                return true
            } catch {
                problem = away(error, "that could not be sent.") ?? "That did not reach your Mac."
                return false
            }
        }
        if sent { offer(undo) }
    }

    /// Delete an archived session (#398), once asked. A refusal says why it cannot go yet.
    func delete(_ agentID: UUID) async {
        guard !isStale(on: work.agent(agentID)?.host ?? .mac) else {
            problem = "Your Mac is not answering, so that could not be sent."
            return
        }
        do {
            try await sendOnce(DaemonAPI.Method.agentsDelete, DaemonAPI.AgentRequest(agentID: agentID))
            if selection == agentID { selection = nil }
        } catch let error as JSONRPCError {
            problem = error.message
        } catch {
            problem = away(error, "that could not be sent.") ?? "That did not reach your Mac."
        }
    }

    /// What is on its way to this agent, if anything: for the control that sent it to
    /// show, and the others to hold (#87).
    func acting(_ agentID: UUID) -> AgentAct? { work.acting[agentID] }

    /// Ask the Mac to start a session's runtime ahead of a prompt (#183): the chat was
    /// opened, or somebody is typing in it. Once per session and reason in a while,
    /// however many keys; the Mac debounces too. Silent: nothing is said if it fails.
    func prewarm(_ agentID: UUID, _ why: DaemonAPI.PrewarmRequest.Why) async {
        guard let agent = agent(agentID), !isStale(agent),
              agent.state == .finished || agent.state == .stopped else { return }
        let key = "\(agentID) \(why.rawValue)"
        if let last = prewarmed[key], Date().timeIntervalSince(last) < 15 { return }
        prewarmed[key] = Date()
        if prewarmed.count > 64 { prewarmed = prewarmed.filter { Date().timeIntervalSince($0.value) < 15 } }
        // To the agent's own host, which is the one with its runtime to start (#238).
        let request = DaemonAPI.PrewarmRequest(agentID: agentID, why: why)
        _ = try? await client(for: request).call(DaemonAPI.Method.agentsPrewarm, request)
    }

    /// Mark as Unread / Mark as Read, from the card's menu (#70).
    func setUnread(_ agentID: UUID, _ unread: Bool) async {
        let host = work.agent(agentID)?.host ?? .mac
        guard !isStale(on: host) else {
            problem = notAnswering(host, "that could not be sent.")
            return
        }
        do {
            // The mark is kept by the agent's own host, and told from there (#238).
            let request = DaemonAPI.SetUnreadRequest(agentID: agentID, unread: unread)
            try await client(for: request).call(DaemonAPI.Method.agentsSetUnread, request)
        } catch {
            problem = away(error, "that could not be sent.") ?? "That did not reach your Mac."
        }
    }

    /// Mute Notifications, or Unmute, from the row's menu or the chat's ··· (#2003).
    func setMuted(_ agentID: UUID, _ muted: Bool, offeringUndo: Bool = true) async {
        let undo = offeringUndo ? work.agent(agentID).flatMap { SessionUndo.muted($0, muted) } : nil
        let sent = await optimistic(.mute(muted), on: agentID) {
            let host = work.agent(agentID)?.host ?? .mac
            guard !isStale(on: host) else {
                problem = notAnswering(host, "that could not be sent.")
                return false
            }
            do {
                // The mark is kept by the agent's own host, which sends no push for it.
                let request = DaemonAPI.SetMutedRequest(agentID: agentID, muted: muted)
                try await client(for: request).call(DaemonAPI.Method.agentsSetMuted, request)
                return true
            } catch {
                problem = away(error, "that could not be sent.") ?? "That did not reach your Mac."
                return false
            }
        }
        if sent { offer(undo) }
    }

    /// Whether this session's host can mute it: one from before #2003 cannot.
    func canMute(_ agent: Agent) -> Bool {
        agent.state != .archived && host(agent.host, has: Capability.mute1)
    }

    /// Something asked of a whole agent, sent once (#87): held in `work.acting` until the
    /// Mac has answered, so the card, its menu, the swipe and the chat all show it going
    /// and none sends a second. Given back, with the problem said, if it did not go.
    @discardableResult
    func act(_ act: AgentAct, on agentID: UUID, _ method: String,
                     _ request: some Encodable & Sendable) async -> Bool {
        guard work.acting[agentID] == nil else { return false }
        return await optimistic(act.write, on: agentID) { await self.sendAct(act, on: agentID, method, request) }
    }

    /// A change drawn on the agent's record at once, before its host answers (#4786):
    /// the kit's one pending layer holds it and puts the record back when the call
    /// fails, with one line that says what failed.
    @discardableResult
    func optimistic(_ write: AgentWrite, on agentID: UUID, _ send: () async -> Bool) async -> Bool {
        let sent = await work.optimistically(write, on: agentID, send)
        if !sent, let said = problem { problem = write.failure(said) }
        return sent
    }

    func sendAct(_ act: AgentAct, on agentID: UUID, _ method: String,
                         _ request: some Encodable & Sendable) async -> Bool {
        guard !isStale(on: work.agent(agentID)?.host ?? .mac) else {
            problem = "Your Mac is not answering, so that could not be sent."
            return false
        }
        guard work.begin(act, on: agentID) else { return false }
        defer { work.end(act, on: agentID) }
        do {
            // To the agent's own host (073), and held no longer than `sendPatience` while
            // that host is away (#208).
            try await sendOnce(method, request)
            return true
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.folderGone
                    || error.code == DaemonAPI.Failure.notAllowed {
            // The Mac's own reason: a folder gone, or Start now past the total (#5156).
            problem = error.message
            return false
        } catch {
            problem = away(error, "that could not be sent.") ?? "That did not reach your Mac."
            return false
        }
    }

    func act(_ method: String, _ agentID: UUID) async -> Bool {
        guard !isStale(on: work.agent(agentID)?.host ?? .mac) else {
            problem = "Your Mac is not answering, so that could not be sent."
            return false
        }
        do {
            // To the agent's own host: one on another of the control plane's hosts is not
            // the home host's to stop or archive (073).
            let request = DaemonAPI.AgentRequest(agentID: agentID)
            try await sendOnce(method, request)
            return true
        } catch {
            problem = away(error, "that could not be sent.") ?? "That did not reach your Mac."
            return false
        }
    }

    /// What to say when a send did not go because its host is away (#208): the home host
    /// or another of the control plane's, by name. Nil for any other failure.
    func away(_ error: any Error, _ outcome: String) -> String? {
        if error is MacAway { return notAnswering(.mac, outcome) }
        guard let away = error as? HostAway else { return nil }
        return notAnswering(away.host, outcome)
    }

    /// "… is not answering, so …", naming the host: the home host as the Mac, another
    /// by its name (#238).
    func notAnswering(_ host: MachineRef, _ outcome: String) -> String {
        "\(host == .mac ? "Your Mac" : hostName(host)) is not answering, so \(outcome)"
    }

    /// Another of the control plane's hosts, by the name it was given.
    func hostName(_ host: MachineRef) -> String {
        controlHosts.first { $0.id == host }.map { $0.name.isEmpty ? $0.id.rawValue : $0.name } ?? "That machine"
    }

    func dismissProblem() { problem = nil }

    /// A failure of something the person did, from a view that holds the call's answer (an
    /// account not added, a device not forgotten): shown as the scene's failure toast (#4737).
    func report(_ problem: String) { self.problem = problem }

#if DEBUG
    /// Open a named folder, and optionally a named agent, straight after connecting.
    ///
    /// Scaffolding for the phase this app is in: there is no Simulator window on this
    /// machine to tap, and a layout nobody can look at is a layout nobody can settle.
    /// `-folder Agents -agent "Lay the remote out for a phone"` lands on that screen.
    ///
    /// It goes when the layout does. What replaces it is the real thing US1 needs: a
    /// notification that lands on the agent it names.
    func openFromLaunchArguments() async {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.index(after: index) < arguments.endIndex
            else { return nil }
            return arguments[arguments.index(after: index)]
        }
        if let name = value("-folder"),
           let summary = work.folders.first(where: { $0.name == name }) {
            // Its page is New session (#366).
            selectedKey = summary.key
            composing = true
        }
        if let title = value("-agent"),
           let agent = work.agents.first(where: { $0.title == title }) {
            selectedKey = FolderKey(host: agent.host, folder: agent.folderPath)
            // A beat, so the folder has been pushed before the conversation is. Two
            // pushes in one turn of the loop is not something to ask of a split view.
            try? await Task.sleep(for: .milliseconds(600))
            selection = agent.id
            // `-archive-open`: then Archive from the chat's bar, for a walk (#2090): the walk
            // socket presses no menu.
            if arguments.contains("-archive-open") {
                try? await Task.sleep(for: .seconds(2))
                await archive(agent.id, andLeave: true)
            }
            // `-move-open`: then Move to Machine… from the chat's ···, for a walk (#4037).
            if arguments.contains("-move-open") {
                try? await Task.sleep(for: .seconds(2))
                movingToMachine = work.agent(agent.id)
            }
        }
        // `-command-menu WORDS`: the ⌘K command menu open with them typed, for a walk (#4792): the
        // walk socket sends no ⌘K. An empty string opens it with nothing typed.
        if let words = value("-command-menu") {
            try? await Task.sleep(for: .seconds(1))
            commandMenu = words
        }
        // `-problem WORDS`: a failure, as an action that failed reports it, for a walk of the
        // scene's failure toast (#4739).
        if let words = value("-problem") {
            try? await Task.sleep(for: .seconds(1))
            report(words)
        }
        // `-workflow` opens a workflow's page on the chosen folder, by its name.
        if let name = value("-workflow"),
           let workflow = work.workflows.first(where: { $0.workflow.name == name }) {
            selectedKey = folderKey(workflow.folder)
            try? await Task.sleep(for: .milliseconds(600))
            openWorkflow = workflow.id
        }
    }
#endif
}
