import Foundation

/// The words for Allow, Ask or Off on a connector's tools (#4099), on the Mac window; the web
/// page says the same (`Web/src/model/connectorTools.ts`).
public enum ConnectorToolWords {
    public static func title(_ level: DaemonAPI.ConnectorToolLevel) -> String {
        switch level {
        case .allow: "Allow"
        case .ask: "Ask"
        case .off: "Off"
        }
    }

    /// What a level does, for its help.
    public static func help(_ level: DaemonAPI.ConnectorToolLevel) -> String {
        switch level {
        case .allow: "Agents use it without asking."
        case .ask: "Agents ask you first."
        case .off: "Agents never use it."
        }
    }

    public static let writesTitle = "Tools that write"
    /// The switch's choice when the layer sets nothing for it.
    public static let eachTool = "Each tool's own"
    /// A tool's choice when the layer sets nothing for it, with what applies then.
    public static func byDefault(_ level: DaemonAPI.ConnectorToolLevel) -> String { "Default (\(title(level)))" }
    public static let writesChip = "writes"
    public static let none = "It has no tools."

    /// The level a tool has when its own is cleared: the writes switch for one that writes,
    /// else Ask for one that writes and Allow for one that only reads, never looser than a cap.
    public static func defaultLevel(_ row: DaemonAPI.MCPToolRow, writes: DaemonAPI.ConnectorToolLevel?) -> DaemonAPI.ConnectorToolLevel {
        var level: DaemonAPI.ConnectorToolLevel = row.writes ? (writes ?? .ask) : .allow
        if let cap = row.cap, cap.order > level.order { level = cap }
        return level
    }
}
