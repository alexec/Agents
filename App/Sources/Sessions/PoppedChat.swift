import AgentsKitCore
import Foundation
import SwiftUI

/// A session open in a window of its own (#826), beside the main window or on another
/// screen.
///
/// The main window's model holds one page of one transcript, the selected chat's. This
/// holds a second page, of this session only, so the two can be read at once. The
/// session itself, its questions and its marks are still the model's: one record of
/// each, so a question answered in one window leaves the other with it.
@MainActor @Observable
final class PoppedChat {
    let id: UUID
    /// Its transcript, and only that: a model of its own that watches this one session.
    let work = AgentsModel()
    /// Bumped when something asks this window's chat to go to its end.
    private(set) var scrollToEndToken = 0
    /// Whether it has been looked for once. Until then, a session not in hand is one
    /// still on its way (a window restored at launch), not one that has gone.
    var looked = false
    /// How many windows show it. One, unless SwiftUI restores a second.
    @ObservationIgnored fileprivate var windows = 0

    init(id: UUID) {
        self.id = id
        work.watching = id
    }

    func scrollToEnd() { scrollToEndToken += 1 }
}

extension AppModel {
    /// A window of its own has opened on this session (#826): its page of the
    /// transcript, loaded, and its host told to send it the session's entries.
    func openPopout(_ id: UUID) -> PoppedChat {
        let chat = popouts[id] ?? PoppedChat(id: id)
        chat.windows += 1
        guard popouts[id] == nil else { return chat }
        chat.work.onOversized = { [weak self] agentID, entryID, index in
            Task { await self?.loadOversized(entryID, of: agentID, at: index) }
        }
        popouts[id] = chat
        popoutsChanged()
        Task { await loadTranscript(of: chat) }
        return chat
    }

    /// Its window has closed. The last one lets the page go.
    func closePopout(_ chat: PoppedChat) {
        chat.windows -= 1
        guard chat.windows <= 0, popouts[chat.id] === chat else { return }
        popouts[chat.id] = nil
        if popoutInFront == chat.id { popoutInFront = nil }
        popoutsChanged()
    }

    /// Whether the window showing this session is the key window: while it is, it is
    /// the one being watched, and a turn finishing there is read (#70).
    func popout(_ id: UUID, isInFront: Bool) {
        if isInFront {
            popoutInFront = id
        } else if popoutInFront == id {
            popoutInFront = nil
        }
        presence?.popped(Set(popouts.keys), inFront: popoutInFront)
    }

    /// Where an entry or terminal output for a session in a window of its own goes too.
    func applyToPopouts(_ update: AgentsModel.Update) {
        switch update {
        case .entry(let note): popouts[note.agentID]?.work.apply(update)
        case .terminalOutput(let note): popouts[note.agentID]?.work.apply(update)
        default: break
        }
    }

    private func popoutsChanged() {
        work.shown.also = Set(popouts.keys)
        presence?.popped(Set(popouts.keys), inFront: popoutInFront)
    }
}

extension EnvironmentValues {
    /// The session this chat is in a window of its own for (#826); nil in the main window,
    /// whose chat is the selection.
    @Entry var poppedChat: PoppedChat? = nil
    /// Whether the window has an inspector beside its chat: the main window and a
    /// folder's (#1089) do, a session's own window (#826) does not.
    @Entry var windowHasInspector = true
}
