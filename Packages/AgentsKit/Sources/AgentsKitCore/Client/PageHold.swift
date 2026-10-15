import Foundation

/// Which showing of a page holds what the page holds open (#1044), such as the runtime
/// behind a phone's New session.
///
/// SwiftUI can say a page went after the page that replaced it said it came: the detail
/// is rebuilt with each pick. Keyed by the showing, not by the page's project, the late
/// "went" of the old one does not let go of what the new one holds.
public struct PageHold<Key: Equatable>: Equatable {
    public private(set) var key: Key?
    private var showing: UUID?

    public init() {}

    /// A showing of the page came, and holds the page from now on.
    public mutating func appeared(_ key: Key, showing: UUID) {
        self.key = key
        self.showing = showing
    }

    /// A showing of the page went. True when it held the page, so what it held goes too.
    public mutating func disappeared(_ showing: UUID) -> Bool {
        guard self.showing == showing else { return false }
        self.showing = nil
        key = nil
        return true
    }

    /// Let go without a showing going, as when what the page made opens in its place.
    public mutating func release() {
        showing = nil
        key = nil
    }
}
