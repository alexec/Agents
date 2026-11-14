import AgentsKitCore
import Foundation
import Observation
import SwiftUI
import UIKit

extension RemoteModel {
    /// A scene of its own has opened on this session: its page of the transcript, loaded,
    /// and its host told to send it the session's entries, as the Mac's windows (#826).
    func openPopout(_ id: UUID) -> PoppedChat {
        let chat = popouts[id] ?? PoppedChat(id: id)
        chat.scenes += 1
        guard popouts[id] == nil else { return chat }
        chat.work.onOversized = { [weak self] agentID, entryID, index in
            Task { await self?.loadOversized(entryID, of: agentID, at: index) }
        }
        popouts[id] = chat
        popoutsChanged()
        Task { await loadTranscript(of: chat) }
        return chat
    }

    /// Its scene has closed. The last one lets the page go.
    func closePopout(_ chat: PoppedChat) {
        chat.scenes -= 1
        guard chat.scenes <= 0, popouts[chat.id] === chat else { return }
        popouts[chat.id] = nil
        if popoutInFront == chat.id { popoutInFront = nil }
        popoutsChanged()
    }

    /// Whether the scene showing this session is the key window: while it is, it is the
    /// one being watched, and a turn finishing there is read (#70).
    func popout(_ id: UUID, isInFront: Bool) {
        if isInFront {
            popoutInFront = id
        } else if popoutInFront == id {
            popoutInFront = nil
        }
        presence?.popped(Set(popouts.keys), inFront: popoutInFront)
    }

    /// Where an entry or terminal output for a session in a scene of its own goes too.
    func applyToPopouts(_ update: AgentsModel.Update) {
        switch update {
        case .entry(let note): popouts[note.agentID]?.work.apply(update)
        case .terminalOutput(let note): popouts[note.agentID]?.work.apply(update)
        case .liveFrame(let frame): popouts[frame.agentID]?.work.apply(update)
        default: break
        }
    }

    /// The page of transcript a chat draws: its scene's own, or the main scene's.
    func page(_ popped: PoppedChat?) -> AgentsModel { popped?.work ?? work }

    /// The session a chat shows: its scene's own, or the main scene's selection.
    func chatID(_ popped: PoppedChat?) -> UUID? { popped?.id ?? selection }

    func popoutsChanged() {
        work.shown.also = Set(popouts.keys)
        presence?.popped(Set(popouts.keys), inFront: popoutInFront)
    }

    /// Archived sessions no screen shows any more, less those in scenes of their own.
    func archivedToLetGo(_ agents: [Agent], folders: Set<URL>, chat: UUID?) -> [UUID] {
        ClientHolding.archivedToLetGo(agents, folders: folders, chat: chat).filter { popouts[$0] == nil }
    }

    /// A session's transcript in a scene of its own, loaded as the main scene's is, into
    /// that scene's own page of it.
    func loadTranscript(of chat: PoppedChat) async {
        let id = chat.id
        let whole = Task { await loadWholeAgent(id) }
        let load = chat.work.beginTranscriptLoad()
        let turnsRequest = DaemonAPI.TurnsRequest.opening(id)
        let pageSize = firstPageSize
        var answered = true
        do {
            let opening = try await ChatOpening.load(
                limit: pageSize,
                turns: {
                    try await client(for: turnsRequest).call(DaemonAPI.Method.agentsTurns, turnsRequest,
                                                             returning: TurnsPage.self)
                },
                transcript: { from, limit in
                    let request = DaemonAPI.TranscriptRequest(agentID: id, limit: limit, from: from)
                    return try await client(for: request).call(DaemonAPI.Method.agentsTranscript, request,
                                                               returning: TranscriptPage.self)
                },
                entry: { index in
                    let request = DaemonAPI.TranscriptRequest.entry(index, of: id)
                    return try await self.client(for: request).call(DaemonAPI.Method.agentsTranscript, request,
                                                                returning: TranscriptPage.self)
                },
                describe: Self.describeLoadFailure)
            // A scene closed while it loaded has nothing to put it in.
            guard popouts[id] === chat else { return }
            _ = chat.work.takeOpening(opening, load: load)
        } catch {
            note("chat: history of \(id) did not load in its own scene: \(error)")
            guard popouts[id] === chat else { return }
            chat.work.failOpening(Self.describeLoadFailure(error), load: load)
            answered = ChatOpening.saysGone(error)
        }
        // Looked for once its host has answered both, as the main scene's (#2743).
        guard await whole.value, answered else { return }
        chat.looked = true
    }

    /// An earlier page of a session in a scene of its own, as `loadEarlier`.
    func loadEarlier(of chat: PoppedChat) async {
        let id = chat.id
        let work = chat.work
        guard work.hasMoreOfTheConversation, !chat.isLoadingEarlier else { return }
        chat.isLoadingEarlier = true
        defer { chat.isLoadingEarlier = false }
        if !work.hasMoreBefore {
            let turnsRequest = DaemonAPI.TurnsRequest(agentID: id, before: work.firstTurn)
            guard let turns = try? await client(for: turnsRequest).call(
                DaemonAPI.Method.agentsTurns, turnsRequest, returning: TurnsPage.self),
                popouts[id] === chat else { return }
            work.prependTurns(turns)
            return
        }
        let request = DaemonAPI.TranscriptRequest(agentID: id, before: work.firstEntryIndex,
                                                  limit: firstPageSize, from: work.openTurnStart)
        guard let page = try? await client(for: request).call(DaemonAPI.Method.agentsTranscript, request,
                                                              returning: TranscriptPage.self),
              popouts[id] === chat else { return }
        work.prepend(page)
    }
}
