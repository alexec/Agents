import AgentsKitCore
import SwiftUI

/// The session list's single keys with an iPad's keyboard (#4796), as the Mac window's: j and k
/// through the open folder's sessions, e archives the session and opens the next, l puts its
/// request in Later, r renames it. Only while the list has the keyboard, so the search field and
/// the prompt bar keep their letters.
struct RemoteListKeys: ViewModifier {
    @Environment(RemoteModel.self) private var model

    func body(content: Content) -> some View {
        content.onKeyPress(characters: CharacterSet(charactersIn: ListKey.characters), phases: .down) { press in
            guard let key = ListKey(typed: press.characters, modified: !press.modifiers.isEmpty) else { return .ignored }
            return perform(key)
        }
    }

    private func perform(_ key: ListKey) -> KeyPress.Result {
        guard model.renaming == nil, model.commandMenu == nil else { return .ignored }
        let current = model.selectedAgent
        switch key {
        case .next, .previous:
            if let id = ListKey.step(from: current?.id, in: model.sessionsInFront, forward: key == .next) { model.sidebarItem = .session(id) }
        case .archive:
            guard let current, current.state != .archived, !model.isStale(current) else { return .ignored }
            let next = ListKey.after(archiving: current.id, in: model.sessionsInFront)
            if let next { model.sidebarItem = .session(next) }
            Task { await model.archive(current.id, andLeave: next == nil) }
        case .later:
            guard let current, let request = model.work.laterRequest(askedBy: current.id) else { return .ignored }
            Task { await model.deferRequest(request, ListKey.laterTime) }
        case .rename:
            guard let current, current.state != .archived, !model.isStale(current) else { return .ignored }
            model.askToRename(current)
        }
        return .handled
    }
}

extension RemoteModel {
    /// The open folder's live sessions, in the order its fold draws them, as the Mac's.
    var sessionsInFront: [UUID] {
        guard let key = selectedKey else { return [] }
        return AgentGroup.live.flatMap { work.agents(in: key, group: $0) }.map(\.id)
    }
}
