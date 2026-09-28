import AgentsKit

/// Whether a session draws the agent's thinking.
///
/// Off unless the person asks. Kept with the other window preferences, and scoped
/// by root the way appearance is, so a scratch copy does not change the real app.
enum ThinkingDisplay {
    static var defaultsKey: String {
        let locations = StoreLocations.default
        return locations.isStandard ? "showsThinking" : "showsThinking.root:\(locations.name)"
    }
}
