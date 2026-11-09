import AgentsKitCore
import SwiftUI

/// What a take-over window shows (#4141): one session's agent browser or simulator. One
/// window per session and source (an iPad scene, the Mac's window): Open again brings it
/// to the front.
struct TakeOverKey: Hashable, Codable, Identifiable {
    var agentID: UUID
    var source: LiveSource

    var id: String { "\(agentID.uuidString)/\(source.rawValue)" }

    /// What the window says it shows, beside the session's title.
    var title: String { source == .simulator ? LiveTileWords.simulator : LiveTileWords.browser }

    /// The scene id: what a take-over window is opened again by.
    static let sceneID = "take-over"
}

extension EnvironmentValues {
    /// This view is in a take-over window (#4141): a hand-off's Open the page has nothing to
    /// open, as the page is already here.
    @Entry var inTakeOver = false
}
