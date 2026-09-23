import Foundation
import Observation

/// Which of the four panes the column is showing.
///
/// One column, four panes, taking turns. The spec's assumption, and the reason a pane
/// is a single case rather than a set.
enum SidebarPane: String, CaseIterable, Identifiable, Sendable {
    case files, terminal, browser, artifacts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: return "Files"
        case .terminal: return "Terminal"
        case .browser: return "Browser"
        case .artifacts: return "Exchanged"
        }
    }

    var symbol: String {
        switch self {
        case .files: return "folder"
        case .terminal: return "apple.terminal"
        case .browser: return "globe"
        case .artifacts: return "tray.full"
        }
    }
}

/// Where the column is: open or not, how wide, which pane.
///
/// This is one person's preference about a window, the same whichever agent is
/// selected, so it is the window's and it is written to `UserDefaults`. It is not the
/// daemon's: the daemon owns things that outlive windows, and a chosen width does not.
@MainActor
@Observable
final class SidebarFrame {
    /// The narrowest the column is worth being, and the widest before it is taking the
    /// window rather than sharing it.
    static let minimumWidth: Double = 280
    static let maximumWidth: Double = 900

    /// Below this, the conversation and the sidebar cannot both be usable, and the app
    /// has to choose. It chooses the conversation. Picked in front of the running app;
    /// see research section 8.
    static let minimumConversationWidth: Double = 520

    private enum Key {
        static let isOpen = "sidebar.isOpen"
        static let width = "sidebar.width"
        static let pane = "sidebar.pane"
    }

    private let defaults: UserDefaults

    /// Closed until asked for. Feature 001 is what you get until you want more, which
    /// is FR-006 expressed as a default rather than as a promise.
    var isOpen: Bool {
        didSet { defaults.set(isOpen, forKey: Key.isOpen) }
    }

    var width: Double {
        didSet { defaults.set(width, forKey: Key.width) }
    }

    var pane: SidebarPane {
        didSet { defaults.set(pane.rawValue, forKey: Key.pane) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isOpen = defaults.bool(forKey: Key.isOpen)
        // Clamped on the way in as well as on the way out. A width stored on a larger
        // screen would otherwise be honoured on a smaller one and leave the
        // conversation with nothing.
        let stored = defaults.object(forKey: Key.width) as? Double
        width = Self.clamp(stored ?? 380)
        pane = (defaults.string(forKey: Key.pane).flatMap(SidebarPane.init(rawValue:))) ?? .files
    }

    static func clamp(_ width: Double) -> Double {
        min(max(width, minimumWidth), maximumWidth)
    }

    /// The most the column may take without leaving the conversation unusable.
    static func maximumWidth(inWindowOf total: Double) -> Double {
        max(minimumWidth, min(maximumWidth, total - minimumConversationWidth))
    }

    /// Whether there is room for the column at all. Below this the control says why
    /// rather than doing nothing, which is the spec's narrow-window edge case.
    static func fits(inWindowOf total: Double) -> Bool {
        total >= minimumConversationWidth + minimumWidth
    }

    func setWidth(_ proposed: Double, inWindowOf total: Double) {
        width = min(Self.clamp(proposed), Self.maximumWidth(inWindowOf: total))
    }
}

/// Where each pane had got to, for one agent, in one window.
///
/// Not persisted. This is where you were looking, not what you decided, and it lasts as
/// long as the window does. Held per agent so that leaving an agent and coming back
/// returns to the same place (FR-005).
@MainActor
@Observable
final class AgentPaneState {
    let agentID: UUID

    /// Nil means the agent's own folder. The pane resolves it, so an agent whose folder
    /// moved does not carry a stale path around.
    var folder: URL?
    var openFile: URL?
    /// Where in the open file to put the reader, counted from one. Set when the agent
    /// asked for this file by line; nil whenever the user opened it themselves, which
    /// is why it is cleared beside `openFile` rather than left to go stale.
    var openLine: Int?
    var browserURL: URL?
    var isAttachedToShell = false

    init(agentID: UUID) {
        self.agentID = agentID
    }
}

/// Every agent's pane state, for this window.
@MainActor
@Observable
final class SidebarStates {
    private var states: [UUID: AgentPaneState] = [:]

    func state(for agentID: UUID) -> AgentPaneState {
        if let existing = states[agentID] { return existing }
        let fresh = AgentPaneState(agentID: agentID)
        states[agentID] = fresh
        return fresh
    }

    /// Nothing is kept for an agent that has gone.
    func forget(_ agentID: UUID) {
        states[agentID] = nil
    }
}
