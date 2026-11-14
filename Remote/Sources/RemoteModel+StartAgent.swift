import AgentsKitCore
import Foundation
import Observation
import SwiftUI
import UIKit

/// The remote's state, part of `RemoteModel` (#5383): see `RemoteModel.swift`.
extension RemoteModel {
    // MARK: Starting an agent (029)

    /// The page goes to whichever showing holds it now (#2089): the one under the showing
    /// that went, or none. `afresh` opens it again even in the same folder, for a showing
    /// that has had nothing behind it since its agent started.
    func startPageMoved(afresh: Bool) {
        let next = startPage.key
        note("start: page now held for \(next?.folder.lastPathComponent ?? "nothing")")
        if afresh, let next, next == startingIn {
            closeStart()
            queueOpenStart(next)
        } else {
            startingIn = next
        }
        if next == nil { startPageLetGo += 1 }
    }

    /// The folders whose New session is asked for now (#2090): the sidebar's pick, and each
    /// folder scene's. What SwiftUI says came and went is not trusted beyond these (#2089).
    var startPagesWanted: [FolderKey] {
        var wanted: [FolderKey] = []
        if case .folder(let key) = sidebarItem { wanted.append(key) }
        for state in folderScenes.values {
            if case .folder(let key) = state.pick { wanted.append(key) }
        }
        return wanted
    }

    /// What is picked moved, here or in a folder's scene: a showing of a page no longer
    /// asked for stops holding it, though it never said it went.
    func startPagesMoved() {
        let wanted = startPagesWanted
        startPage.keep { wanted.contains($0) }
        if startPage.key != startingIn, !isStarting { startPageMoved(afresh: false) }
    }

    /// The page came on screen. Opened afresh each time, even in the same folder: a
    /// showing that went without saying so left nothing this one can trust.
    func startPageAppeared(in folder: FolderKey, page: UUID) {
        startPage.appeared(folder, showing: page)
        note("start: page appeared for \(folder.folder.lastPathComponent)")
        guard startingIn == folder else { startingIn = folder; return }
        closeStart()
        queueOpenStart(folder)
    }

    /// A showing that said it went is still on screen (#2089), and nothing holds the page:
    /// it holds it again. Not one whose agent has started, which is on its way out, nor
    /// while one starts.
    func startPageStillShown(in folder: FolderKey, page: UUID) {
        guard startingIn == nil, !isStarting, !startedPages.contains(page),
              startPagesWanted.contains(folder) else { return }
        note("start: page still shown for \(folder.folder.lastPathComponent), held again")
        startPageAppeared(in: folder, page: page)
    }

    /// The page went. Nothing, when another showing has taken it since.
    func startPageDisappeared(_ page: UUID) {
        if startPage.disappeared(page) { startPageMoved(afresh: false) }
    }

    /// What a ui:// view filled the page with (#834), for the page in its folder to take
    /// once it is on screen. The person still presses Start.
    struct OfferedStart: Equatable {
        let folder: FolderKey
        let start: AppViewStart
    }

    /// Open the New session page in a view's folder, filled in (#834), as New Session
    /// opens it. Why it did not open, or nil.
    func offerStart(_ start: AppViewStart, in key: FolderKey) -> String? {
        guard let summary = work.folder(key) else { return "This folder isn’t one the phone knows." }
        guard !isStarting else { return "An agent is starting. Try again once it has." }
        offeredStart = OfferedStart(folder: summary.key, start: start)
        offeredWorktree = start.worktreeChoice.map { (folder: summary.key, choice: $0) }
        sidebarItem = .folder(summary.key)
        // Already open in this folder: its repository is asked again for the worktree.
        if start.worktreeChoice != nil, startingIn == summary.key {
            Task { await loadStartWorktrees(in: summary.key) }
        }
        return nil
    }

    /// The session a view's `agents/message-agent` goes to (#837): on the branch, in this folder.
    func recipient(of message: AppViewAgentMessage, in key: FolderKey) -> AppViewRecipient? {
        message.recipient(among: work.agents, host: key.host, folder: key.folder)
            .map { AppViewRecipient(id: $0.id, name: AppViewAgentMessage.name(of: $0)) }
    }
}
