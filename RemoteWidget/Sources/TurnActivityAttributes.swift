import ActivityKit
import AgentsKitCore
import Foundation

/// The turns sent from this phone or iPad, as one Live Activity (#1657, #2991).
///
/// Compiled into the Remote, which starts, updates and ends it, and into the widget
/// extension, which draws it: ActivityKit matches the two by this type. The activity speaks
/// for every turn sent from here, and the session it shows changes, so nothing about a
/// session is fixed here: all of it is `TurnActivityContent`, worked out in Core. An
/// activity from a build before #2991, with a session's fields, still decodes, and the
/// Remote ends all but one.
struct TurnActivityAttributes: ActivityAttributes {
    typealias ContentState = TurnActivityContent
}
