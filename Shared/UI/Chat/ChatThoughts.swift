import AgentsKitCore
import SwiftUI

/// Whether the chat draws the agent's thoughts (#1725). Off at first: most people do not
/// want to read the agent's thinking. Kept on this device only, as the smart-group switches
/// are (#846); the web page keeps the same choice in its local storage. Turned on and off
/// next to the chat (#2383): View ▸ Show Thoughts on the Mac, the chat's ··· menu on the
/// Remote and the web page.
enum ChatThoughts {
    static let showsKey = "showsThoughts"
    static let showsAtFirst = false

    /// `items` as the chat draws them: with the thoughts, or with them left off.
    static func shown(_ items: [TranscriptItem], showsThoughts: Bool) -> [TranscriptItem] {
        showsThoughts ? items : items.omittingThoughts()
    }

    /// The menu item's words, as Show Inspector / Hide Inspector say what it will do.
    static func menuTitle(showsThoughts: Bool) -> String {
        showsThoughts ? "Hide Thoughts" : "Show Thoughts"
    }

    static let menuHelp = "Show each of the agent's thoughts as one folded line in the chat, or leave them out"
}
