import AgentsKitCore
import Foundation
import Observation

/// What the source list (column 1) has picked, and so what the list (column 2) lists
/// (#866): Mail's mailboxes and messages.
enum ListSource: Hashable {
    /// A page about all the work. It fills columns 2 and 3: there is no list beside it.
    case activity(SidebarItem)
    /// Pinned, Needs You, Working or Unread, across every project.
    case smart(SidebarSmartRow)
    /// One project's sessions, workflows and pages.
    case project(ProjectKey)
}

/// The window's second column (#866): which list it shows, whether it shows, and how
/// wide. One for the window, beside `SidebarFrame` (the inspector), so the menu bar can
/// hide it too.
@MainActor
@Observable
final class ListColumn {
    static let minWidth: CGFloat = 220
    static let maxWidth: CGFloat = 520
    private static let widthKey = "sessionList.width"
    private static let shownKey = "sessionList.isShown"
    private static let sourceKey = "sessionList.source"

    /// What column 1 has picked. Nil before anything is: column 2 then lists Needs You.
    var source: ListSource? {
        didSet { store(source) }
    }

    /// Hidden by View ▸ Hide Session List (⌥⌘S), for a narrow screen with the inspector
    /// open. Kept, as Mail keeps its message list hidden.
    var isShown: Bool {
        didSet { UserDefaults.standard.set(isShown, forKey: Self.shownKey) }
    }

    var width: CGFloat {
        didSet { UserDefaults.standard.set(Double(width), forKey: Self.widthKey) }
    }

    init() {
        let defaults = UserDefaults.standard
        isShown = defaults.object(forKey: Self.shownKey) as? Bool ?? true
        let stored = defaults.double(forKey: Self.widthKey)
        width = stored > 0 ? min(max(stored, Self.minWidth), Self.maxWidth) : 300
        source = Self.restored(defaults.string(forKey: Self.sourceKey))
    }

    /// There is a list to show: not beside an Activity page, which fills its column.
    var hasList: Bool {
        if case .activity = source { return false }
        return true
    }

    /// The list column shows: there is a list, and it is not hidden.
    var isDrawn: Bool { hasList && isShown }

    // A smart group or a project is kept; an Activity page is not, as the window does
    // not reopen on the bill.
    private func store(_ source: ListSource?) {
        let defaults = UserDefaults.standard
        switch source {
        case .smart(let row): defaults.set("smart:" + row.rawValue, forKey: Self.sourceKey)
        case .project(let key): defaults.set("project:" + key.stored, forKey: Self.sourceKey)
        case .activity, nil: break
        }
    }

    private static func restored(_ stored: String?) -> ListSource? {
        guard let stored else { return nil }
        if stored.hasPrefix("smart:") {
            return SidebarSmartRow(rawValue: String(stored.dropFirst(6))).map(ListSource.smart)
        }
        if stored.hasPrefix("project:") {
            return ProjectKey(stored: String(stored.dropFirst(8))).map(ListSource.project)
        }
        return nil
    }
}
