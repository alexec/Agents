import AgentsKitCore
import AppKit
import Foundation
import os

/// Pinned pages and pinned sessions (#159, #180).
extension AppModel {
    // MARK: Pinned pages (#159)

    func pins(in folder: URL?) -> [PinView] { work.pins(in: folder) }
    /// The folder's servers' list views (#2032), the hidden ones too.
    func serverViews(in folder: URL?) -> [PinView] { work.serverViews(in: folder) }
    func pageRevision(in folder: URL?) -> Int { work.pageRevision(in: folder) }

    func refreshPins() async {
        guard let listed = try? await client.call(DaemonAPI.Method.pinsList, DaemonAPI.Empty(),
                                                  returning: [FolderPins].self) else { return }
        work.replacePins(listed)
    }

    /// The open requests to the person (#3864), for Needs You; `requests/changed` keeps them.
    func refreshRequests() async {
        guard let listed = try? await client.call(DaemonAPI.Method.requestsList, DaemonAPI.RequestsListRequest(),
                                                  returning: DaemonAPI.RequestsListResult.self) else { return }
        work.replaceRequests(listed.requests)
    }

    /// A file of a folder's, for a pinned page, a page tile, or what an HTML page draws.
    func readPage(_ path: String, in key: FolderKey, known: FileStamp? = nil) async throws -> FileReading {
        try await client(for: key.host).call(DaemonAPI.Method.pinsRead,
                                             DaemonAPI.PinReadRequest(folder: key.folder, path: path, knownStamp: known),
                                             returning: FileReading.self)
    }

    /// What the person typed on a pinned Markdown page. Why it was not saved, or nil.
    func writePage(_ path: String, in key: FolderKey, text: String) async -> String? {
        do {
            try await client(for: key.host).call(DaemonAPI.Method.pinsWrite,
                                                 DaemonAPI.PinWriteRequest(folder: key.folder, path: path, text: text))
            return nil
        } catch let error as JSONRPCError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    /// Pin to Folder, from the files pane: a path absolute on the folder's host.
    func pin(_ path: String, in key: FolderKey) async {
        await attempt(on: key.host) {
            let pins = try await self.client(for: key.host).call(DaemonAPI.Method.pinsPin,
                                                                 DaemonAPI.PinRequest(folder: key.folder, path: path),
                                                                 returning: [PinView].self)
            self.work.setPins(pins, in: key.folder)
        }
    }

    /// Pin a view under a folder (#189), from its menu in a chat. Why it was not, or nil.
    /// A view's `agents/start-agent` (#834): the folder's page, its bar filled in. Why
    /// not, or nil.
    func offerStart(_ start: AppViewStart, in key: FolderKey) -> String? {
        let wanted = Folder.standardize(key.folder)
        guard let folder = folders.first(where: {
            $0.host == key.host && Folder.standardize($0.folder.folder) == wanted
        }) else {
            return "\(key.folder.lastPathComponent) is not a folder here."
        }
        showFolder(FolderKey(host: key.host, folder: folder.folder.folder))
        offeredStart = OfferedStart(folder: folder.folder.folder, start: start)
        return nil
    }

    /// The session a view's `agents/message-agent` goes to (#837): on the branch, in this folder.
    func recipient(of message: AppViewAgentMessage, in key: FolderKey) -> AppViewRecipient? {
        message.recipient(among: agents, host: key.host, folder: key.folder)
            .map { AppViewRecipient(id: $0.id, name: AppViewAgentMessage.name(of: $0)) }
    }

    func pinView(_ view: ViewPin, in key: FolderKey) async -> String? {
        do {
            let pins = try await client(for: key.host).call(DaemonAPI.Method.pinsPin,
                                                            DaemonAPI.PinRequest(folder: key.folder, view: view),
                                                            returning: [PinView].self)
            work.setPins(pins, in: key.folder)
            return nil
        } catch let error as JSONRPCError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    func unpin(_ path: String, in key: FolderKey) async {
        work.setPins(pins(in: key.folder).filter { $0.path != path }, in: key.folder)
        if openPin == path, selectedFolderKey == key { showFolder(key) }
        await attempt(on: key.host) {
            try await self.client(for: key.host).call(DaemonAPI.Method.pinsUnpin,
                                                      DaemonAPI.PinPathRequest(folder: key.folder, path: path))
        }
    }

    /// Dismiss on a pull request in For Review (#3330): gone at once, then the host told,
    /// which keeps it out for good.
    func dismissReview(_ pull: ReviewPull, in key: FolderKey) async {
        work.dismissReview(pull.url, in: key.folder)
        await attempt(on: key.host) {
            try await self.client(for: key.host).call(DaemonAPI.Method.reviewsDismiss,
                                                      DaemonAPI.ReviewDismissRequest(folder: key.folder, url: pull.url))
        }
    }

    /// A press on a pull request in For Review (#3464): drawn read at once, then the host told,
    /// which keeps it, so every client draws it read.
    func openReview(_ pull: ReviewPull, in key: FolderKey) async {
        guard pull.isUnread else { return }
        work.openReview(pull.url, in: key.folder)
        await attempt(on: key.host) {
            try await self.client(for: key.host).call(DaemonAPI.Method.reviewsOpen,
                                                      DaemonAPI.ReviewOpenRequest(folder: key.folder, url: pull.url))
        }
    }

    /// Start on a suggestion of the daily checks in For Review (#3331): the host starts a
    /// session in its folder with its prompt, and the window opens it.
    func startSuggestion(_ suggestion: CheckSuggestion, in key: FolderKey) async {
        var started: UUID?
        let ok = await attempt(on: key.host) {
            started = try await self.client(for: key.host).call(DaemonAPI.Method.suggestionsStart,
                                                                DaemonAPI.SuggestionRequest(folder: key.folder, id: suggestion.id),
                                                                returning: UUID.self)
        }
        guard ok, let started else { return }
        work.dropSuggestion(suggestion.id, in: key.folder)
        openAgent(started)
    }

    /// Dismiss on a suggestion of the daily checks in For Review (#3331): gone at once, then
    /// the host told, which keeps it out for good.
    func dismissSuggestion(_ suggestion: CheckSuggestion, in key: FolderKey) async {
        work.dropSuggestion(suggestion.id, in: key.folder)
        await attempt(on: key.host) {
            try await self.client(for: key.host).call(DaemonAPI.Method.suggestionsDismiss,
                                                      DaemonAPI.SuggestionRequest(folder: key.folder, id: suggestion.id))
        }
    }

    /// Hide or Show on a server's list view (#2032): shown at once, then the host told.
    func setViewHidden(_ uri: String, _ hidden: Bool, in key: FolderKey) async {
        work.setViewHidden(uri, hidden, in: key.folder)
        if hidden, openPin == uri, selectedFolderKey == key { showFolder(key) }
        await attempt(on: key.host) {
            try await self.client(for: key.host).call(DaemonAPI.Method.pinsHideView,
                                                      DaemonAPI.PinHideViewRequest(folder: key.folder, uri: uri, hidden: hidden))
        }
    }

    /// A drop or a Move item: shown at once, then the whole order sent once.
    func arrangePins(_ paths: [String], in key: FolderKey) async {
        let held = pins(in: key.folder)
        work.setPins(paths.compactMap { path in held.first { $0.path == path } }, in: key.folder)
        await attempt(on: key.host) {
            try await self.client(for: key.host).call(DaemonAPI.Method.pinsArrange,
                                                      DaemonAPI.PinArrangeRequest(folder: key.folder, paths: paths))
        }
    }

    // MARK: Pinned sessions (#180)

    func pinnedSessions(in folder: URL?) -> [UUID] { work.pinnedSessions(in: folder) }

    func isPinned(_ agent: Agent) -> Bool {
        pinnedSessions(in: agent.folderPath).contains(agent.id)
    }

    /// Pin or Unpin from a session's menu or swipe: shown at once, then the host told.
    func setPinned(_ agent: Agent, _ pinned: Bool) async {
        let folder = agent.folderPath
        let held = pinnedSessions(in: folder).filter { $0 != agent.id }
        work.setSessionPins(pinned ? held + [agent.id] : held, in: folder)
        await attempt(on: agent.host) {
            try await self.client(for: agent.host).call(
                pinned ? DaemonAPI.Method.pinsPinSession : DaemonAPI.Method.pinsUnpinSession,
                DaemonAPI.PinSessionRequest(folder: folder, agentID: agent.id))
        }
    }

    /// A drop or a Move item among the pinned sessions: shown at once, the order sent once.
    func arrangeSessionPins(_ ids: [UUID], in key: FolderKey) async {
        work.setSessionPins(ids, in: key.folder)
        await attempt(on: key.host) {
            try await self.client(for: key.host).call(DaemonAPI.Method.pinsArrangeSessions,
                                                      DaemonAPI.PinArrangeSessionsRequest(folder: key.folder, agentIDs: ids))
        }
    }
}
