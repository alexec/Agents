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
