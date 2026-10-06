import AgentsKitCore
import Foundation
import Observation

/// The panes the phone can open beside a conversation: the Mac's, less its browser (034).
///
/// No Browser case, on purpose, rather than one kept disabled. The Mac's browser shows
/// the agent's local servers, which only listen on the Mac, and a pane that could never
/// show anything is not offered (FR-030).
enum Pane: String, CaseIterable, Identifiable, Hashable {
    case page, files, changes, terminal, exchanged

    var id: String { rawValue }

    var title: String {
        switch self {
        case .page: "Page"
        case .files: "Files"
        case .changes: "Changes"
        case .terminal: "Terminal"
        case .exchanged: "Exchanged"
        }
    }
}

/// One agent's pane on this device: which is open and where in it the person was.
///
/// The phone's `AgentPaneState`. Kept for as long as the app runs and no longer, and
/// never told to the Mac: where somebody is reading is not the daemon's business, and a
/// place carried across a relaunch would open on a file that has since moved (FR-026).
@MainActor
@Observable
final class PaneState {
    /// Nil when no pane is open.
    var pane: Pane?
    /// The last pane shown, so the Panes button opens where the person left off.
    var lastPane: Pane?
    /// The Markdown file on the Page. Nil until one has been opened, and the Page is
    /// not offered until then.
    var pagePath: String?
    /// The folder Files is showing. Nil means the agent's own folder.
    var folder: URL?
    /// Folders open in the iPad's Files tree, by `FileTree.key` (#345). The phone shows
    /// a folder at a time and leaves this alone.
    var expanded: Set<String> = []
    /// The file open in Files, if any.
    var openFile: URL?
    /// The file last open, marked in the folder, and whether the list still has to be
    /// scrolled to it (#66).
    var place = FileTreePlace()
    /// The line an agent or a tool call named. Spent once it has been gone to.
    var openLine: Int?
    /// Where the reader was in each file: the passage or line index at the top.
    var scrollAnchor: [String: Int] = [:]
    /// "What the agent did" is over the open file.
    var showingChanges = false
    /// An HTML file shows its source rather than its page (#67). One choice for the
    /// pane; an agent's `show_file` puts the page back.
    var htmlShowsSource = false
    /// HTML files the person let run scripts, by path. Off for every other file.
    var scriptsAllowed: Set<String> = []
    /// A file the Changes pane should open when it appears.
    var changesPath: String?
    /// The terminal tabs, by shell number, left to right, as the window has them (055,
    /// #345). Filled from the Mac each time the pane is shown, so the phone opens on
    /// the shells still running rather than only the first.
    var shells: [Int] = [0]
    /// The tab on top.
    var frontShell = 0
    /// False when the agent's daemon holds only one shell — a server not yet updated.
    var canOpenMoreShells = true

    /// Open a pane, remembering it as the one to come back to.
    func show(_ pane: Pane) {
        self.pane = pane
        lastPane = pane
    }

    /// Open a file where it belongs: a Markdown file on the Page, anything else in
    /// Files at the line.
    func open(file url: URL, line: Int?) {
        if ShownFile.isMarkdown(url) {
            pagePath = url.path
            openLine = line
            show(.page)
        } else {
            folder = url.deletingLastPathComponent()
            openFile = url
            openLine = line
            showingChanges = false
            show(.files)
        }
    }

    /// What the Panes button opens: where the person was, else the Page if there is
    /// one, else Files.
    var defaultPane: Pane {
        if let lastPane, lastPane != .page || pagePath != nil { return lastPane }
        return pagePath != nil ? .page : .files
    }
}

/// Every agent's pane on this device, and how wide the person likes the column.
@MainActor
@Observable
final class RemotePanes {
    private var states: [UUID: PaneState] = [:]
    /// What the column was last dragged to. One width for every agent: it is a fact
    /// about the person's screen, not about the work.
    var preferredColumnWidth: Double?

    func state(for agentID: UUID) -> PaneState {
        if let state = states[agentID] { return state }
        let state = PaneState()
        states[agentID] = state
        return state
    }
}

/// Returns once the task it runs in is cancelled: what a `.task` waits on to let go of
/// something it took for as long as its view is shown.
func untilCancelled() async {
    while !Task.isCancelled { try? await Task.sleep(for: .seconds(3_600)) }
}
