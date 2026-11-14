import AgentsKitCore
import Foundation
import Observation
import SwiftUI
import UIKit

/// The remote's state, part of `RemoteModel` (#5383): see `RemoteModel.swift`.
extension RemoteModel {
    // MARK: Pinned pages (#159)

    /// What this agent changed, from the daemon's bounded change list (#245).
    func changes(for agentID: UUID) async throws -> ChangesList {
        try await client.call(DaemonAPI.Method.changesList,
                              DaemonAPI.ChangesListRequest(agentID: agentID),
                              returning: ChangesList.self)
    }

    func changeDetail(for agentID: UUID, path: String, whole: Bool = false) async throws -> ChangedFileDetail {
        try await client.call(DaemonAPI.Method.changesFile,
                              DaemonAPI.ChangesFileRequest(agentID: agentID, path: path, whole: whole),
                              returning: ChangedFileDetail.self)
    }

    func pins(in folder: URL?) -> [PinView] { work.pins(in: folder) }

    /// The folder's servers' list views (#2032), the hidden ones too.
    func serverViews(in folder: URL?) -> [PinView] { work.serverViews(in: folder) }

    /// Dismiss on a pull request in For Review (#3330): gone at once, then the host told,
    /// which keeps it out for good.
    func dismissReview(_ pull: ReviewPull, in folder: URL) async {
        work.dismissReview(pull.url, in: folder)
        do {
            try await client.call(DaemonAPI.Method.reviewsDismiss,
                                  DaemonAPI.ReviewDismissRequest(folder: folder, url: pull.url))
        } catch {
            problem = sentence(for: error)
        }
    }

    /// A press on a pull request in For Review (#3464): drawn read at once, then the host told,
    /// which keeps it, so every client draws it read.
    func openReview(_ pull: ReviewPull, in folder: URL) async {
        guard pull.isUnread else { return }
        work.openReview(pull.url, in: folder)
        do {
            try await client.call(DaemonAPI.Method.reviewsOpen,
                                  DaemonAPI.ReviewOpenRequest(folder: folder, url: pull.url))
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Start on a suggestion of the daily checks in For Review (#3331): the host starts a
    /// session in its folder with its prompt, and it opens here.
    func startSuggestion(_ suggestion: CheckSuggestion, in folder: URL) async {
        do {
            let id = try await client.call(DaemonAPI.Method.suggestionsStart,
                                           DaemonAPI.SuggestionRequest(folder: folder, id: suggestion.id), returning: UUID.self)
            work.dropSuggestion(suggestion.id, in: folder)
            _ = await loadWholeAgent(id)
            selectedKey = FolderKey(host: .mac, folder: folder)
            openWorkflow = nil
            selection = id
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Dismiss on a suggestion of the daily checks in For Review (#3331): gone at once, then
    /// the host told, which keeps it out for good.
    func dismissSuggestion(_ suggestion: CheckSuggestion, in folder: URL) async {
        work.dropSuggestion(suggestion.id, in: folder)
        do {
            try await client.call(DaemonAPI.Method.suggestionsDismiss,
                                  DaemonAPI.SuggestionRequest(folder: folder, id: suggestion.id))
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Hide or Show on a server's list view (#2032): shown at once, then the host told.
    func setViewHidden(_ uri: String, _ hidden: Bool, in folder: URL) async {
        work.setViewHidden(uri, hidden, in: folder)
        if hidden, openPin == uri { openPin = nil }
        do {
            try await client.call(DaemonAPI.Method.pinsHideView,
                                  DaemonAPI.PinHideViewRequest(folder: folder, uri: uri, hidden: hidden))
        } catch {
            problem = sentence(for: error)
        }
    }

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
        publishAttention()
    }

    /// A file of the folder's: a pinned page, a page tile's, or what an HTML page draws.
    func readPage(_ path: String, in folder: URL, known: FileStamp? = nil) async throws -> FileReading {
        try await client.call(DaemonAPI.Method.pinsRead,
                              DaemonAPI.PinReadRequest(folder: folder, path: path, knownStamp: known),
                              returning: FileReading.self)
    }

    /// What the person typed on a pinned Markdown page. Why it was not saved, or nil.
    func writePage(_ path: String, in folder: URL, text: String) async -> String? {
        do {
            try await client.call(DaemonAPI.Method.pinsWrite, DaemonAPI.PinWriteRequest(folder: folder, path: path, text: text))
            return nil
        } catch {
            return sentence(for: error)
        }
    }

    func pin(_ path: String, in folder: URL) async {
        do {
            let pins = try await client.call(DaemonAPI.Method.pinsPin, DaemonAPI.PinRequest(folder: folder, path: path),
                                             returning: [PinView].self)
            work.setPins(pins, in: folder)
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Pin a view under a folder (#189), from its menu in a chat. Why it was not, or nil.
    func pinView(_ view: ViewPin, in folder: URL) async -> String? {
        do {
            let pins = try await client.call(DaemonAPI.Method.pinsPin, DaemonAPI.PinRequest(folder: folder, view: view),
                                             returning: [PinView].self)
            work.setPins(pins, in: folder)
            return nil
        } catch {
            return sentence(for: error)
        }
    }

    func unpin(_ path: String, in folder: URL) async {
        work.setPins(pins(in: folder).filter { $0.path != path }, in: folder)
        if openPin == path { openPin = nil }
        do {
            try await client.call(DaemonAPI.Method.pinsUnpin, DaemonAPI.PinPathRequest(folder: folder, path: path))
        } catch {
            problem = sentence(for: error)
        }
    }

    /// A Move item or a drag in Edit: shown at once, then the whole order sent once.
    func arrangePins(_ paths: [String], in folder: URL) async {
        let held = pins(in: folder)
        work.setPins(paths.compactMap { path in held.first { $0.path == path } }, in: folder)
        do {
            try await client.call(DaemonAPI.Method.pinsArrange, DaemonAPI.PinArrangeRequest(folder: folder, paths: paths))
        } catch {
            problem = sentence(for: error)
        }
    }

    // MARK: Pinned sessions (#180)

    func pinnedSessions(in folder: URL?) -> [UUID] { work.pinnedSessions(in: folder) }

    func isPinned(_ agent: Agent) -> Bool {
        pinnedSessions(in: agent.folderPath).contains(agent.id)
    }

    /// Pin or Unpin from a card's menu or swipe: shown at once, then the Mac told.
    func setPinned(_ agent: Agent, _ pinned: Bool) async {
        let folder = agent.folderPath
        let held = pinnedSessions(in: folder).filter { $0 != agent.id }
        work.setSessionPins(pinned ? held + [agent.id] : held, in: folder)
        do {
            try await client.call(pinned ? DaemonAPI.Method.pinsPinSession : DaemonAPI.Method.pinsUnpinSession,
                                  DaemonAPI.PinSessionRequest(folder: folder, agentID: agent.id))
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Move Up or Move Down among the pinned sessions: shown at once, the order sent once.
    func arrangeSessionPins(_ ids: [UUID], in folder: URL) async {
        work.setSessionPins(ids, in: folder)
        do {
            try await client.call(DaemonAPI.Method.pinsArrangeSessions,
                                  DaemonAPI.PinArrangeSessionsRequest(folder: folder, agentIDs: ids))
        } catch {
            problem = sentence(for: error)
        }
    }

    // MARK: Pinned workflows (#432)

    func pinnedWorkflows(in folder: URL?) -> [String] { work.pinnedWorkflows(in: folder) }

    func isPinned(_ summary: WorkflowSummary) -> Bool {
        pinnedWorkflows(in: summary.folder).contains(summary.workflowID)
    }

    /// Pin or Unpin from a workflow's menu, swipe or page: shown at once, then the host told.
    func setPinned(_ summary: WorkflowSummary, _ pinned: Bool) async {
        let folder = summary.folder
        let held = pinnedWorkflows(in: folder).filter { $0 != summary.workflowID }
        work.setWorkflowPins(pinned ? held + [summary.workflowID] : held, in: folder)
        do {
            let request = DaemonAPI.WorkflowRequest(folder: folder, workflowID: summary.workflowID)
            try await client(for: request).call(
                pinned ? DaemonAPI.Method.pinsPinWorkflow : DaemonAPI.Method.pinsUnpinWorkflow, request)
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Move Up or Move Down among the pinned workflows: shown at once, the order sent once.
    func arrangeWorkflowPins(_ ids: [String], in folder: URL) async {
        work.setWorkflowPins(ids, in: folder)
        do {
            let request = DaemonAPI.PinArrangeWorkflowsRequest(folder: folder, workflowIDs: ids)
            try await client(for: request).call(DaemonAPI.Method.pinsArrangeWorkflows, request)
        } catch {
            problem = sentence(for: error)
        }
    }
}
