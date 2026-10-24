import Foundation

/// Which showing of a page holds what the page holds open (#1044), such as the runtime
/// behind a phone's New session.
///
/// SwiftUI can say a page went after the page that replaced it said it came: the detail
/// is rebuilt with each pick. Keyed by the showing, not by the page's folder, the late
/// "went" of the old one does not let go of what the new one holds.
///
/// More than one showing can be on screen at once (#2089): an iPhone's folder screen over
/// the sidebar of every folder, an iPad's folder scene beside the main one. The last to
/// come holds the page; when it goes, the one under it holds it again, so a page still on
/// screen is never left with nothing behind it.
public struct PageHold<Key: Equatable>: Equatable {
    private var showings: [Showing] = []

    private struct Showing: Equatable {
        let id: UUID
        let key: Key
    }

    public init() {}

    /// What the holding showing is for, or nil when no showing is on screen.
    public var key: Key? { showings.last?.key }

    /// A showing of the page came, and holds the page from now on.
    public mutating func appeared(_ key: Key, showing: UUID) {
        showings.removeAll { $0.id == showing }
        showings.append(Showing(id: showing, key: key))
    }

    /// A showing of the page went. True when it held the page: what it held goes too, and
    /// `key` is now the showing's under it, if one is still on screen.
    public mutating func disappeared(_ showing: UUID) -> Bool {
        let held = showings.last?.id == showing
        showings.removeAll { $0.id == showing }
        return held
    }

    /// Drops every showing whose page is no longer asked for (#2089): a showing can go
    /// without saying so, and must not hold the page from under the one on screen.
    public mutating func keep(where wanted: (Key) -> Bool) {
        showings.removeAll { !wanted($0.key) }
    }

    /// Let go without a showing going, as when what the page made opens in its place: the
    /// holding showing is going, and the one under it, if any, holds the page.
    public mutating func release() {
        if !showings.isEmpty { showings.removeLast() }
    }
}
