import AgentsKitCore
import Foundation
import Observation
import SwiftUI
import UIKit

/// The remote's state, part of `RemoteModel` (#5383): see `RemoteModel.swift`.
extension RemoteModel {
    // MARK: The conversation

    /// The open chat's record whole, with the menus and plan a lean list leaves out (#107).
    /// A Mac too old to know `agentID` lists its newest instead, which is not this one.
    /// Whether its host answered, with it or without it (#2743).
    @discardableResult
    func loadWholeAgent(_ id: UUID) async -> Bool {
        let request = DaemonAPI.ListRequest.whole(id)
        guard let listed = try? await client(for: request).call(DaemonAPI.Method.agentsList, request,
                                                                returning: [Agent].self) else { return false }
        guard var whole = listed.first(where: { $0.id == id }) else { return true }
        whole.host = work.agent(id)?.host ?? whole.host
        work.takeListed([whole])
        return true
    }

    func loadTranscript() async {
        guard let selection else { work.clearTranscript(); return }
        // Beside the transcript rather than before it, and not cancelled by its returns.
        let whole = Task { await loadWholeAgent(selection) }
        // The last few finished turns as summaries, as the window opens with (#242), then
        // the turn in progress. A Mac too old to keep turns gives the lot. Both from the
        // chat's own host (058).
        //
        // Only the latest load puts its answer on screen: opening the chat and a
        // catch-up both load it, and the older answer could land last (#400).
        let load = work.beginTranscriptLoad()
        // What was fetched for it under the pointer or beside the last one opened, at once
        // (#4795); else this device's copy of its end, while the Mac's page is on its way (#4791).
        // Awaited when nothing of the chat is held, so a reconnect or a launch can resume from
        // the copy's end (#4794): a read of one small file, not a wait on the Mac.
        if localCopy?.drawPrefetched(of: selection, load: load) != true, work.transcriptEnd == nil {
            await localCopy?.drawOpening(of: selection, load: load)
        }
        // What was written since the end held (#4794), one page from it, in place of the whole
        // opening; a page that leaves a gap, or no answer, opens it whole.
        if await work.resumeTranscript(load: load, transcript: { from, limit in
            let request = DaemonAPI.TranscriptRequest(agentID: selection, limit: limit, from: from)
            return try await self.client(for: request).call(DaemonAPI.Method.agentsTranscript, request,
                                                            returning: TranscriptPage.self)
        }) != nil {
            guard await whole.value, self.selection == selection else { return }
            lookedForSelection = selection
            return
        }
        let turnsRequest = DaemonAPI.TurnsRequest.opening(selection)
        let pageSize = firstPageSize
        // Whether its host answered: with the history, or that it has no such session.
        var answered = true
        do {
            let opening = try await ChatOpening.load(
                limit: pageSize,
                turns: {
                    try await client(for: turnsRequest).call(DaemonAPI.Method.agentsTurns, turnsRequest,
                                                             returning: TurnsPage.self)
                },
                transcript: { from, limit in
                    let request = DaemonAPI.TranscriptRequest(agentID: selection, limit: limit, from: from)
                    return try await client(for: request).call(DaemonAPI.Method.agentsTranscript, request,
                                                               returning: TranscriptPage.self)
                },
                entry: { index in
                    let request = DaemonAPI.TranscriptRequest.entry(index, of: selection)
                    return try await self.client(for: request).call(DaemonAPI.Method.agentsTranscript, request,
                                                                returning: TranscriptPage.self)
                },
                describe: Self.describeLoadFailure)
            // A chat left before its page arrived does not get that page shown under the
            // next one's name.
            guard self.selection == selection else { return }
            if work.takeOpening(opening, load: load) {
                localCopy?.opened(selection, opening)
                // The rows either side, which are opened next (#4795).
                prefetchNeighbours(of: selection)
            }
            if let why = opening.turnsFailure { note("chat: turns of \(selection) did not load: \(why)") }
        } catch {
            // Said in the chat, with Try Again, where it used to stay blank without a
            // word until the next reconnect (#400).
            note("chat: history of \(selection) did not load: \(error)")
            guard self.selection == selection else { return }
            work.failOpening(Self.describeLoadFailure(error), load: load)
            answered = ChatOpening.saysGone(error)
        }
        // Looked for once its host has answered both: from here a session not in hand has
        // gone (#2652). A call that failed is no answer, and the chat says it with Try
        // Again rather than calling the session deleted (#2743).
        guard await whole.value, answered, self.selection == selection else { return }
        lookedForSelection = selection
    }

    /// A chat's opening page from its host, as `loadTranscript` reads it, for a prefetch.
    func fetchOpening(_ id: UUID) async throws -> ChatOpening.Loaded {
        let turnsRequest = DaemonAPI.TurnsRequest.opening(id)
        return try await ChatOpening.load(
            limit: firstPageSize,
            turns: {
                try await self.client(for: turnsRequest).call(DaemonAPI.Method.agentsTurns, turnsRequest,
                                                              returning: TurnsPage.self)
            },
            transcript: { from, limit in
                let request = DaemonAPI.TranscriptRequest(agentID: id, limit: limit, from: from)
                return try await self.client(for: request).call(DaemonAPI.Method.agentsTranscript, request,
                                                                returning: TranscriptPage.self)
            },
            entry: { index in
                let request = DaemonAPI.TranscriptRequest.entry(index, of: id)
                return try await self.client(for: request).call(DaemonAPI.Method.agentsTranscript, request,
                                                                returning: TranscriptPage.self)
            },
            describe: Self.describeLoadFailure)
    }

    /// Fetches a chat before it is opened (#4795): the row under an iPad's pointer, and the
    /// rows beside the open one. Not the open one, and not one whose host is not answering.
    func prefetch(_ id: UUID) {
        guard id != selection, let agent = work.agent(id), !isStale(agent) else { return }
        localCopy?.prefetched.prefetch(id) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.fetchOpening(id)
        }
    }

    /// The live sessions of the open one's folder, in the order its list draws them, either
    /// side of it.
    func prefetchNeighbours(of id: UUID) {
        guard let agent = work.agent(id) else { return }
        let key = FolderKey(host: agent.host, folder: agent.folderPath)
        let list = AgentGroup.live.flatMap { work.agents(in: key, group: $0) }.map(\.id)
        for neighbour in OpeningPrefetch.neighbours(of: id, in: list) { prefetch(neighbour) }
    }

    /// A chat's history that did not come, in words (#400).
    static func describeLoadFailure(_ error: any Error) -> String {
        switch error {
        // The strip over the chat says why; this, what is shown, in the window's words (#963).
        case is HostAway: OfflineWords.lastHeard
        case let error as JSONRPCError where error.code == DaemonAPI.Failure.hostOffline: OfflineWords.lastHeard
        case is MacAway: "your Mac can't be reached right now."
        case is DaemonClient.NoAnswer: "no answer from your Mac in time."
        case let error as JSONRPCError: error.message
        default: "the connection to your Mac was lost."
        }
    }

    /// An entry its host sent as a stub, too big to send to every chat (#203), read here.
    func loadOversized(_ entryID: UUID, of agentID: UUID, at index: Int?) async {
        let request = DaemonAPI.TranscriptRequest.around(index, of: agentID)
        guard let page = try? await client(for: request).call(DaemonAPI.Method.agentsTranscript, request,
                                                              returning: TranscriptPage.self),
              let entry = page.entries.first(where: { $0.id == entryID }) else { return }
        work.fillOversized(entry, for: agentID)
        popouts[agentID]?.work.fillOversized(entry, for: agentID)
    }

    /// A finished turn's entries, for the chat to open it: the last page of them when
    /// the turn is longer than a host gives in one answer (#200).
    /// Nil when they did not come, which the chat says and asks again for (#400).
    func turnEntries(_ agentID: UUID, _ range: Range<Int>) async -> TranscriptPage? {
        let request = DaemonAPI.TranscriptRequest(agentID: agentID, before: range.upperBound,
                                                  limit: min(range.count, DaemonAPI.TranscriptRequest.limitCeiling),
                                                  from: range.lowerBound)
        do {
            return try await client(for: request).call(DaemonAPI.Method.agentsTranscript, request,
                                                       returning: TranscriptPage.self)
        } catch {
            note("chat: steps of \(agentID) did not load: \(error)")
            return nil
        }
    }

    /// Another page, backwards. Never the whole history: that is the difference
    /// between a conversation opening in a second and one opening on a train.
    /// A source file's problems, from its language server on the agent's host (#844).
    /// A failure is thrown, for the editor to say (#1687).
    func diagnose(path: String, text: String, of agentID: UUID) async throws -> DaemonAPI.FileDiagnostics {
        let request = DaemonAPI.FileDiagnosticsRequest(agentID: agentID, path: path, text: text)
        return try await client(for: request).call(DaemonAPI.Method.filesDiagnostics, request,
                                                   returning: DaemonAPI.FileDiagnostics.self)
    }

    /// What the file's language server would write at a line and column (#1603), or why
    /// there is nothing: the host's reason, or the failure (#1688).
    func complete(path: String, text: String, line: Int, column: Int, of agentID: UUID) async -> DaemonAPI.FileCompletions {
        let request = DaemonAPI.FileCompletionRequest(agentID: agentID, path: path, text: text, line: line, column: column)
        do {
            return try await client(for: request).call(DaemonAPI.Method.filesComplete, request,
                                                       returning: DaemonAPI.FileCompletions.self)
        } catch {
            return DaemonAPI.FileCompletions(items: [], reason: DaemonAPI.FileCompletions.failure(error))
        }
    }

    /// The take-over window's view of the browser on a session's host (#3800), made once
    /// per host. Nil while that host cannot be reached from here.
    func machineBrowser(for agentID: UUID) -> MachineBrowser? {
        let host = work.agent(agentID)?.host ?? .mac
        if let existing = machineBrowsers[host] { return existing }
        guard let client = try? client(for: DaemonAPI.AgentRequest(agentID: agentID)) else { return nil }
        let fresh = MachineBrowser(client: client, describe: Self.describeBrowserFailure)
        // Copy and Cut in the page put its selection on this device's pasteboard (#5119).
        fresh.copied = { UIPasteboard.general.string = $0 }
        machineBrowsers[host] = fresh
        return fresh
    }

    func receivedBrowser(_ method: String, _ params: JSONValue?, from host: MachineRef) {
        machineBrowsers[host]?.received(method, params)
    }

    /// A browser call that failed, in words, under the page.
    static func describeBrowserFailure(_ error: any Error) -> String {
        switch error {
        case is HostAway: "The machine can't be reached right now."
        case is MacAway: "Your Mac can't be reached right now."
        case is DaemonClient.NoAnswer: "No answer from the machine in time."
        case let error as JSONRPCError: error.message
        default: "The connection to the machine was lost."
        }
    }

    /// The Simulator pane's calls (#842), to the session's host.
    func simulatorCalls(for agentID: UUID) -> SimulatorCalls {
        let host = { try self.client(for: DaemonAPI.AgentRequest(agentID: agentID)) }
        return SimulatorCalls(
            list: { try await host().call(DaemonAPI.Method.simulatorsList, Optional<String>.none,
                                          returning: DaemonAPI.SimulatorList.self) },
            boot: { udid in _ = try await host().call(DaemonAPI.Method.simulatorsBoot,
                                                      DaemonAPI.SimulatorRequest(udid: udid)) },
            shutdown: { udid in _ = try await host().call(DaemonAPI.Method.simulatorsShutdown,
                                                          DaemonAPI.SimulatorRequest(udid: udid)) },
            screen: { udid, maxHeight in try await host().call(
                DaemonAPI.Method.simulatorsScreen, DaemonAPI.SimulatorScreenRequest(udid: udid, maxHeight: maxHeight),
                                                    returning: DaemonAPI.SimulatorScreen.self) },
            tap: { udid, x, y in _ = try await host().call(
                DaemonAPI.Method.simulatorsTap, DaemonAPI.SimulatorTapRequest(udid: udid, x: x, y: y)) },
            home: { udid in _ = try await host().call(
                DaemonAPI.Method.simulatorsHome, DaemonAPI.SimulatorRequest(udid: udid)) })
    }

    /// Find in Chat (#1532): what was said in a chat that holds `text`, found by its host.
    func find(_ text: String, in agentID: UUID) async -> DaemonAPI.FindResult? {
        let request = DaemonAPI.FindRequest(agentID: agentID, text: text)
        return try? await client(for: request).call(DaemonAPI.Method.agentsFind, request,
                                                    returning: DaemonAPI.FindResult.self)
    }

    /// Go to a match in the open chat: earlier pages come in until its turn is in hand
    /// (`AgentsModel.reveal`, bounded), then the chat goes to it, or as near as it can.
    func reveal(_ match: DaemonAPI.FindMatch) async {
        await work.reveal(index: match.index) { await self.loadEarlier(turns: $0) }
        focusedIndex = match.index
        focusedEntry = match.entryID
    }

    func loadEarlier(turns limit: Int = 50) async {
        guard let selection, work.hasMoreOfTheConversation, !isLoadingEarlier else { return }
        isLoadingEarlier = true
        defer { isLoadingEarlier = false }
        // Past the start of the turn in progress, the turns before it.
        if !work.hasMoreBefore {
            let turnsRequest = DaemonAPI.TurnsRequest(agentID: selection, before: work.firstTurn, limit: limit)
            guard let turns = try? await client(for: turnsRequest).call(
                DaemonAPI.Method.agentsTurns, turnsRequest, returning: TurnsPage.self),
                self.selection == selection else { return }
            work.prependTurns(turns)
            return
        }
        let request = DaemonAPI.TranscriptRequest(agentID: selection, before: work.firstEntryIndex,
                                                  limit: firstPageSize, from: work.openTurnStart)
        guard let page = try? await client(for: request).call(DaemonAPI.Method.agentsTranscript, request,
                                                              returning: TranscriptPage.self) else { return }
        guard self.selection == selection else { return }
        work.prepend(page)
    }

    // MARK: Doing something about it

    /// Answer the question the agent is blocked on.
    ///
    /// Refused here and now when the Mac is not answering, rather than accepted and
    /// quietly dropped (FR-033). An answer that cannot be delivered is not an answer.
    @discardableResult
    func answer(_ request: PermissionRequest, optionID: String) async -> Bool {
        // The card goes at once, and comes back if the answer did not go (#4786).
        await work.answering(request) { await sendAnswer(request, optionID: optionID) }
    }

    func sendAnswer(_ request: PermissionRequest, optionID: String) async -> Bool {
        let host = work.agent(request.agentID)?.host ?? .mac
        guard !isStale(on: host) else {
            problem = notAnswering(host, "that could not be sent.")
            return false
        }
        do {
            try await sendOnce(DaemonAPI.Method.permissionsAnswer,
                               DaemonAPI.AnswerRequest(permissionID: request.id, optionID: optionID,
                                                       sendID: UUID()))
            return true
        } catch {
            problem = away(error, "that could not be sent.") ?? "That question could not be answered."
            return false
        }
    }

    /// Answer the form the agent is blocked on.
    ///
    /// Refused here when the Mac is not answering, exactly as a permission is: an
    /// answer that cannot be delivered is not an answer, and an agent left waiting
    /// while the person believes they replied is the worst of both.
    @discardableResult
    func answer(_ request: ElicitationRequest,
                action: DaemonAPI.AnswerElicitationRequest.Action,
                content: [String: JSONValue] = [:], reason: String? = nil) async -> Bool {
        // The card goes at once, and comes back if the answer did not go (#4786).
        await work.answering(request) {
            await sendAnswer(request, action: action, content: content, reason: reason)
        }
    }

    func sendAnswer(_ request: ElicitationRequest, action: DaemonAPI.AnswerElicitationRequest.Action,
                            content: [String: JSONValue], reason: String?) async -> Bool {
        let host = work.agent(request.agentID)?.host ?? .mac
        // An empty reason is No thanks (#4039).
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStale(on: host) else {
            problem = notAnswering(host, "that could not be sent.")
            return false
        }
        do {
            try await sendOnce(DaemonAPI.Method.elicitationsAnswer,
                               DaemonAPI.AnswerElicitationRequest(requestID: request.id, action: action,
                                                                  content: content, sendID: UUID(),
                                                                  reason: reason?.isEmpty == false ? reason : nil))
            return true
        } catch {
            // The daemon refuses an answer that does not fit the shape the agent asked
            // for, and says why. Its words, not ours: it knows which field was wrong.
            problem = (error as? JSONRPCError)?.message ?? away(error, "that could not be sent.")
                ?? "That question could not be answered."
            return false
        }
    }

    /// An answer pressed on a banner (#1170): the card's own answer, the same call to the
    /// same host, sent with the app in the background, perhaps just woken for it.
    ///
    /// Back in touch first, as a background refresh is, and caught up when the question
    /// is not held yet. A question no longer asked was answered somewhere else: nothing
    /// is sent, and the catch-up's sweep takes its banner away. An answer that did not go
    /// puts the banner back, silently, so the question is not lost with it. The log says
    /// the need, the button and how it went, never what was typed.
    @discardableResult
    func answerFromBanner(_ token: String, _ quick: QuickAnswer, typed: String?) async -> Bool {
        let began = ContinuousClock.now
        note("banner: \(token) \(quick.kind.rawValue) pressed")
        if !isConnected {
            if !reconnect.isRunning { Task { await connect() } }
            await goBackNow(.wake)
            let deadline = ContinuousClock.now + Self.bannerPatience
            while !isConnected, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        if bannerQuestion(token) == nil { await catchUp() }
        let sent: Bool
        switch bannerQuestion(token) {
        case .permission(let request):
            sent = await answer(request, optionID: quick.id)
        case .elicitation(let request):
            guard let content = quick.content(typed: typed) else {
                note("banner: \(token) nothing to send")
                return false
            }
            sent = await answer(request, action: .accept, content: content)
        case .secretUse(let request):
            guard let action = NeedRequest.Action(rawValue: quick.id) else { return false }
            sent = await answerSecretUse(request, action)
        case nil:
            note("banner: \(token) is over, nothing sent, in \(ContinuousClock.now - began)")
            return false
        }
        note("banner: \(token) \(sent ? "answered" : "not sent"), in \(ContinuousClock.now - began)")
        if !sent, let need = work.needs.first(where: { $0.key.token == token })?.value {
            notifier.showAgain(need)
        }
        return sent
    }

    enum BannerQuestion {
        case permission(PermissionRequest)
        case elicitation(ElicitationRequest)
        case secretUse(NeedRequest)
    }

    /// The question a banner's token names, while it is still asked.
    func bannerQuestion(_ token: String) -> BannerQuestion? {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "permission":
            return work.permissions.first { $0.id.uuidString == parts[1] }.map(BannerQuestion.permission)
        case "elicitation":
            return work.elicitations.first { $0.id.uuidString == parts[1] }.map(BannerQuestion.elicitation)
        case "request":
            return work.requests.first { $0.id.uuidString == parts[1] && $0.secretUse != nil }.map(BannerQuestion.secretUse)
        default:
            return nil
        }
    }

    /// Say something to an agent that already exists, with whatever goes with it.
    ///
    /// Answers whether it went, so the prompt bar can keep what was typed when it did
    /// not. A prompt that could not be delivered and was cleared from the field anyway
    /// is the worst outcome here: the person believes they asked, and nothing did.
    ///
    /// An agent mid-turn is not refused — the daemon queues it and gets to it after
    /// this turn. That is the daemon's rule and it is deliberately not second-guessed
    /// from here. What is attached is checked first, by the same rules as a start from
    /// the phone (029): nothing the runtime cannot take, and nothing too big for the link.
    /// `voice`: sent from voice mode (#2322), so the reply is short and fit to be heard.
    func send(_ what: String, attachments: [Attachment] = [], to agentID: UUID, voice: Bool = false) async -> Bool {
        // In the chat at once, as the person's bubble, until the host's entry lands (#4814).
        let drawn = work.beginSending(what, to: agentID)
        let sent = await deliver(what, attachments: attachments, to: agentID, voice: voice)
        work.endSending(drawn, to: agentID, sent: sent)
        return sent
    }

    func deliver(_ what: String, attachments: [Attachment], to agentID: UUID, voice: Bool) async -> Bool {
        let host = work.agent(agentID)?.host ?? .mac
        // A stopped workspace that starts when used: kept by the control plane (#691 US3).
        if host != .mac, isStale(on: host), startsWhenUsed(host) {
            guard attachments.isEmpty else {
                problem = "Attachments can’t wait for \(hostName(host)) to start. Send the words alone, or start it first."
                return false
            }
            guard await keepThroughControl(host, DaemonAPI.Method.agentsPrompt,
                                           DaemonAPI.PromptRequest(agentID: agentID, text: what, sendID: UUID(), voice: voice ? true : nil)) != nil
            else { return false }
            turnSent(to: agentID)
            return true
        }
        guard !isStale(on: host) else {
            problem = notAnswering(host, "that was not sent.")
            return false
        }
        let runtimeID = work.agent(agentID)?.runtimeID
        let capabilities = promptCapabilities(for: runtimeID)
        let runtime = promptRuntimeName(for: runtimeID)
        if let refused = attachments.lazy.compactMap({ PhoneAttachment.refusal(for: $0, from: capabilities, runtime: runtime) }).first {
            problem = refused
            return false
        }
        if let tooMuch = PhoneAttachment.totalRefusal(attachments) {
            problem = tooMuch
            return false
        }
        do {
            try await sendOnce(DaemonAPI.Method.agentsPrompt,
                               DaemonAPI.PromptRequest(agentID: agentID, text: what,
                                                       attachments: attachments, sendID: UUID(),
                                                       voice: voice ? true : nil))
            turnSent(to: agentID)
            return true
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.couldNotSave {
            // It reached the Mac, which could not write it down (#88).
            problem = error.message + " What you typed is still there."
            return false
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.folderGone {
            // Its folder has gone (#119): said with the ways on, carrying what was typed.
            folderGone = FolderGoneAsk(agentID: agentID, message: error.message, text: what,
                                       attachments: attachments)
            return false
        } catch let error where DaemonAPI.PolicyRefusal(error: error) != nil {
            // The organisation's policy refused the turn (#998): its own words, not a lost Mac.
            problem = DaemonAPI.PolicyRefusal(error: error)!.line + " What you typed is still there."
            return false
        } catch {
            problem = (away(error, "that was not sent.") ?? "That did not reach your Mac.") + " What you typed is still there."
            return false
        }
    }

    /// A prompt went from here: its turn in the Live Activity (#1657, #2991).
    func turnSent(to agentID: UUID) {
        liveActivities.sent(to: agentID, in: work)
    }

    /// Back to the end of the conversation, as the Mac does when a prompt goes.
    func scrollToEnd() { scrollToEndToken += 1 }
}
