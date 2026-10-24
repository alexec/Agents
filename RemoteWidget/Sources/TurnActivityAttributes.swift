import ActivityKit
import AgentsKitCore
import Foundation

/// A turn sent from this phone or iPad, as a Live Activity (#1657).
///
/// Compiled into the Remote, which starts, updates and ends it, and into the widget
/// extension, which draws it: ActivityKit matches the two by this type. What does not
/// change for the life of the activity is here; what does is `TurnActivityContent`, worked
/// out in Core.
struct TurnActivityAttributes: ActivityAttributes {
    typealias ContentState = TurnActivityContent

    /// The session, for a tap to open it and for at most one activity each.
    var agentID: UUID
    /// The runtime's name, "Claude".
    var runtime: String
    /// The folder's name.
    var folder: String
    /// The session's title when the activity started, for a pushed state, which has none
    /// (#1744). Nil from a build before it.
    var title: String?
}
