import SwiftUI

/// A run of unchanged lines, hidden: says how many, and opens them in place (041 FR-010).
///
/// The row is the button, edge to edge, so a click anywhere on it opens the fold: padding
/// outside a plain button is dead space.
struct FoldRow: View {
    let count: Int
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.and.down")
                    .imageScale(.small)
                Text(count == 1 ? "1 unchanged line" : "\(count) unchanged lines")
            }
            .appText(.fine)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the unchanged lines")
        .accessibilityLabel(count == 1 ? "1 unchanged line, hidden" : "\(count) unchanged lines, hidden")
        .accessibilityHint("Shows them")
    }
}
