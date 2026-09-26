import Foundation

/// How much a mode lets an agent do without asking, so one mode can be weighed against
/// another.
///
/// For one decision: an agent starting another may give it its own mode or a stricter
/// one, never a looser one. Otherwise an agent the person keeps on a short lead hands
/// the work to one on none, and the lead was for nothing.
///
/// Every runtime names its modes its own way, so this knows the names the runtimes in
/// the catalogue advertise and nothing else. A name it does not know has no place, and
/// a mode with no place is never shown to be as strict as another.
public enum ModeLooseness {
    /// Nought is read-only planning; four asks about nothing. Copilot sends its modes
    /// as URLs, so the part after `#` is what is looked up.
    static let ranks: [String: Int] = [
        "plan": 0, "ask": 0,
        "default": 1,
        "acceptEdits": 2, "agent": 2,
        "auto": 3,
        "bypassPermissions": 4, "autopilot": 4,
    ]

    public static func rank(_ mode: String) -> Int? {
        let name = mode.split(separator: "#").last.map(String.init) ?? mode
        return ranks[name]
    }

    /// Whether `wanted` asks no less often than `limit`. The same name always is,
    /// known or not.
    public static func isNoLooser(_ wanted: String, than limit: String) -> Bool {
        if wanted == limit { return true }
        guard let wantedRank = rank(wanted), let limitRank = rank(limit) else { return false }
        return wantedRank <= limitRank
    }
}
