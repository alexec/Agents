import Foundation

/// The person's display choices that follow them from one client to the next (#1033), kept
/// once on the host in `~/.agents/settings/display.json`.
///
/// The names are the keys the Mac and the Remote have always kept them under in their own
/// defaults, which now hold a mirror of the host's map (`DisplayPreferenceMirror`) so every
/// view can go on reading them where it did. The web page keeps no copy.
public enum DisplayPreference {
    /// The smart groups that are off, comma-separated (`SidebarSmartRow.offDefaultsKey`).
    public static let smartGroupsOff = "sidebarSmartGroupsOff"
    /// Whether the sidebar shows archived folders, and its Activity and Usage sections.
    public static let showsArchivedFolders = "showsArchivedFolders"
    public static let showsActivity = "showsActivity"
    public static let showsUsage = "showsUsage"
    /// The runtime the start form offers first.
    public static let startRuntimeID = "startRuntimeID"
    /// The choices last made on the start form, per runtime: `{runtimeID: {optionID: value}}`.
    public static let startChoices = "startChoices"
    /// The model and permission levels last chosen on a start form (#3798):
    /// `{"model": …, "permission": …}`, so a new session does not fall back to Ask.
    public static let startLevels = "startLevels"
    /// The marketplace last chosen in Add Skill and Add MCP Server.
    public static let skillsMarketplace = "catalog.skills.marketplace"
    public static let mcpMarketplace = "catalog.mcp.marketplace"
    /// Whether a chat the person started may archive itself when it ends done (#1802). On
    /// unless they turn it off; the host reads it when such a turn ends.
    public static let agentsMayArchiveMyChats = "agentsMayArchiveMyChats"
    public static let agentsMayArchiveMyChatsDefault = true
    /// The person's attention (#2805): how many notices agents may send at once, and how
    /// many minutes one takes to come back. Every agent on the host shares them; the host
    /// reads them each time an agent calls `notify`.
    public static let noticeBurst = "noticeBurst"
    public static let noticeBurstDefault = 3
    public static let noticeBurstRange = 1...20
    public static let noticeCooldownMinutes = "noticeCooldownMinutes"
    public static let noticeCooldownDefault = 10
    public static let noticeCooldownRange = 1...1440
    /// The cool-downs the Mac and the Remote offer in a menu (#2896): a Stepper took 50
    /// presses from 10 to 60 minutes. The web keeps its number field, so a value set there
    /// may be none of these; the menu then shows it as well.
    public static let noticeCooldownPresets = [1, 5, 10, 15, 30, 60, 120, 240, 480, 1440]
    /// The person's Multiplier baseline (#3991), from Settings ▸ Cost ▸ Multiplier: merged PRs
    /// a week, and the line under the figures. Absent is the 2025 figure and its line; the
    /// host counts with them and sends them on `multiplier/changed`.
    public static let multiplierPRsPerWeek = "multiplierPRsPerWeek"
    public static let multiplierPRsPerWeekDefault = 1.4
    public static let multiplierPRsPerWeekRange = 0.1...100.0
    public static let multiplierLine = "multiplierLine"

    /// The ones kept as a plain value in a client's defaults, and the kind of each.
    public enum Kind: Sendable { case bool, string, int }
    public static let mirrored: [String: Kind] = [
        smartGroupsOff: .string,
        showsArchivedFolders: .bool, showsActivity: .bool, showsUsage: .bool,
        startRuntimeID: .string, skillsMarketplace: .string, mcpMarketplace: .string,
        agentsMayArchiveMyChats: .bool,
        noticeBurst: .int, noticeCooldownMinutes: .int,
    ]
}

extension DisplayPreference {
    /// The levels kept under `startLevels`; a level not kept, or not known, is the default's.
    public static func keptLevels(in preferences: DaemonAPI.DisplayPreferences,
                                   default fallback: Levels = Levels(model: .balanced, permission: .ask)) -> Levels {
        let kept = preferences[startLevels]?.objectValue ?? [:]
        var levels = fallback
        if let model = kept["model"]?.stringValue.flatMap(ModelLevel.init(rawValue:)) { levels.model = model }
        if let permission = kept["permission"]?.stringValue.flatMap(PermissionLevel.init(rawValue:)) { levels.permission = permission }
        return levels
    }

    /// The change that keeps levels' model and permission under `startLevels`, or none when
    /// they are kept already.
    public static func keeping(_ levels: Levels, in preferences: DaemonAPI.DisplayPreferences) -> DaemonAPI.DisplayPreferences {
        var kept: [String: JSONValue] = [:]
        if let model = levels.model { kept["model"] = .string(model.rawValue) }
        if let permission = levels.permission { kept["permission"] = .string(permission.rawValue) }
        return preferences[startLevels] == .object(kept) ? [:] : [startLevels: .object(kept)]
    }
}
