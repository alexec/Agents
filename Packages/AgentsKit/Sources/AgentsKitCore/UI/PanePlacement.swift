import Foundation

/// Where a pane goes on a phone or an iPad: beside the conversation, or over it (034).
///
/// A function of widths and nothing else. A size class would guess, and guess wrong
/// for an iPad in a narrow Split View, which has a large screen and a phone's room.
/// What decides is whether the conversation keeps its comfortable reading width with a
/// pane beside it that still holds a readable line.
public enum PanePlacement: Equatable, Sendable {
    /// Beside the conversation, this wide.
    case column(paneWidth: Double)
    /// Over the conversation, with a way back to it.
    case fullScreen

    /// The narrowest a pane may be: a page at the phone's reading step still holds
    /// sixty characters here, `PageMetrics`' floor.
    public static let minimumPaneWidth = 360.0
    /// The rule between the two columns.
    public static let divider = 1.0

    /// The narrowest window that takes a column: 660 + 360 + 1.
    public static var columnThreshold: Double {
        ChatMetrics.comfortablePane + minimumPaneWidth + divider
    }

    /// - Parameter preferredPaneWidth: what the person last dragged the column to,
    ///   if they have. Held to between the minimum and half the window.
    public static func decide(width: Double, preferredPaneWidth: Double? = nil) -> PanePlacement {
        guard width >= columnThreshold else { return .fullScreen }
        let widest = max(minimumPaneWidth, width / 2)
        let wanted = preferredPaneWidth ?? minimumPaneWidth
        return .column(paneWidth: min(widest, max(minimumPaneWidth, wanted)))
    }
}
