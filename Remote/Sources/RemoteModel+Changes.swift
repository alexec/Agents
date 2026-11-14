import AgentsKitCore
import Foundation
import Observation
import SwiftUI
import UIKit

/// The remote's state, part of `RemoteModel` (#5383): see `RemoteModel.swift`.
extension RemoteModel {
    // MARK: Which files the agent changed (034)

    /// The files an agent changed since it started, as the Mac marks them: from the
    /// transcript, never the disk (FR-011). The page of it that is loaded, plus what was
    /// read of the rest when Files opened.
    func touchedPaths(for agentID: UUID) -> TouchedPaths {
        var touched = touchedEarlier[agentID] ?? TouchedPaths()
        if selection == agentID { for entry in work.entries { touched.absorb(entry) } }
        // And a scene of its own's page of it (#888).
        if let popped = popouts[agentID] { for entry in popped.work.entries { touched.absorb(entry) } }
        return touched
    }

    /// Read the part of the conversation the chat has not loaded, once, so a file the
    /// agent edited an hour ago is marked here as it is on the Mac (research §5). Paged,
    /// backwards, as "load earlier" is; kept apart from the chat's own page.
    func loadTouchedHistory(for agentID: UUID) async {
        guard !touchedHistoryAsked.contains(agentID) else { return }
        touchedHistoryAsked.insert(agentID)
        let request = DaemonAPI.AgentRequest(agentID: agentID)
        guard let paths = try? await client(for: request).call(
            DaemonAPI.Method.agentsTouchedPaths, request, returning: [String].self) else {
            touchedHistoryAsked.remove(agentID)
            return
        }
        touchedEarlier[agentID] = TouchedPaths(paths: paths)
    }

    /// Open what the agent asked for, and take it off the model so it is asked once.
    /// "Look at this" is about a moment, and the moment has passed by the next launch.
    ///
    /// Where it opens is the Mac's answer (034 FR-004): a Markdown file on the Page, any
    /// other file in Files at the line. A Mac without the panes gets today's sheet.
    /// While the person is typing it is not opened: it is taken off all the same, and its
    /// Object card in the chat opens it when the person chooses (034 FR-005, #5035).
    func openFileTheAgentWants() {
        guard let selection, let file = work.takeFileToShow(for: selection) else { return }
        if !isTyping { open(file, for: selection) }
    }

    /// A file shown in the chat, opened again from its card (#836).
    func openShownFile(_ file: ShownFile) {
        guard let selection else { return }
        work.rememberChart(file)
        open(file, for: selection)
    }

    /// A plan being approved, reopened from its question card: the same page the
    /// daemon opened when it was asked.
    func openPlan(_ file: ShownFile) {
        guard let selection else { return }
        open(file, for: selection)
    }

    func open(_ file: ShownFile, for agentID: UUID) {
        if macLacksPanes {
            fileOnScreen = file.path
        } else {
            let state = panes.state(for: agentID)
            // An agent showing a page means the page (#67).
            if HTMLPageScope.isHTML(file.url) { state.htmlShowsSource = false }
            state.open(file: file.url, line: file.line)
        }
    }

    /// Whether what is on screen can still be trusted, and acted on.
    ///
    /// Stale is not an error. It is the honest answer for a Mac that is asleep, and
    /// the screens say so and stop offering actions rather than pretending (FR-035).
    var isStale: Bool { !isConnected }

    /// When what the phone shows was last read (#5141): the last word from the control plane,
    /// or the moment a live link went, whichever is later; before either, this device's copy.
    var lastReadAt: Date? {
        [lastHeardFrom, liveUntil].compactMap { $0 }.max() ?? work.copyReadAt
    }
}
