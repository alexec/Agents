import AgentsKitCore
#if !AGENTS_STORE
import AgentsKit
#endif
import Foundation

/// The level every turn starts at (069): View ▸ Turns.
///
/// Kept with the other window preferences, and scoped by root the way appearance is,
/// so a scratch copy does not change the real app.
enum TurnDisplay {
    static var defaultsKey: String {
        let locations = StoreLocations.default
        return locations.isStandard ? "turnDetail" : "turnDetail.root:\(locations.name)"
    }

    /// Where View ▸ Show Thinking kept its switch, before thinking became part of Details.
    private static var thinkingKey: String {
        let locations = StoreLocations.default
        return locations.isStandard ? "showsThinking" : "showsThinking.root:\(locations.name)"
    }

    /// Before anyone has chosen: Details for someone who had Show Thinking on, since
    /// that is where thinking is now, and the outcome for everyone else.
    static var initial: TurnDetail {
        UserDefaults.standard.bool(forKey: thinkingKey) ? .details : .outcome
    }
}
