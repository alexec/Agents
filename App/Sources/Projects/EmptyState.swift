import SwiftUI

/// One empty state: a title, a short line of what to do, and optional actions.
///
/// Used wherever a column or page has nothing to show, so the wording and layout stay
/// the same for no project, a missing folder, and an empty list.
struct EmptyState: View {
    let title: String
    let detail: String
    var systemImage: String? = nil

    var body: some View {
        ContentUnavailableView {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        } description: {
            Text(detail)
        }
    }
}

extension EmptyState {
    /// No project is selected in the middle or detail column.
    static var noProject: EmptyState {
        EmptyState(title: "No project",
                   detail: "Choose one on the left, or add a folder.",
                   systemImage: "folder")
    }

}
