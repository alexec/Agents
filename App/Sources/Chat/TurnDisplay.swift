import AgentsKitCore
import Foundation

/// The level every turn starts at (069): View ▸ Turns.
///
/// Kept with the other window preferences, in `WindowDefaults`, so a scratch copy does
/// not change the real app.
enum TurnDisplay {
    static let defaultsKey = "turnDetail"

    /// Where View ▸ Show Thinking kept its switch, before thinking became part of Details.
    private static let thinkingKey = "showsThinking"

    /// Before anyone has chosen: Details for someone who had Show Thinking on, since
    /// that is where thinking is now, and Messages for everyone else (#993).
    static var initial: TurnDetail {
        WindowDefaults.store.bool(forKey: thinkingKey) ? .details : .initial
    }
}
