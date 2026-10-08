import SwiftUI

/// The row of terminal tabs over the screen, with the button that opens another (055).
///
/// Shared since #345: the window and the Remote draw the same tabs over the same
/// shells, which the daemon holds by number. What a tab is called is what the program
/// in it says, or else its place in the row, not its number, so closing one renames
/// those after it.
///
/// Every tab can be closed, the last too: the pane opens a fresh shell in its place
/// (#401).
struct ShellTabs: View {
    /// The shells, by number, left to right.
    let shells: [Int]
    /// What the program in each says it is (OSC 0/2), when it says (#401).
    var titles: [Int: String] = [:]
    let front: Int
    /// False when the agent's daemon holds only one shell — a server not yet updated.
    let canOpenMore: Bool
    let select: (Int) -> Void
    let open: () -> Void
    let close: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            // More tabs than fit scroll sideways, and the one on top is kept in view:
            // a tab just opened at the end of a narrow column is otherwise off the edge.
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(shells.enumerated()), id: \.element) { position, shell in
                            ShellTab(title: titles[shell].flatMap { $0.isEmpty ? nil : $0 } ?? "Shell \(position + 1)",
                                     isFront: front == shell,
                                     canClose: true,
                                     select: { select(shell) },
                                     close: { close(shell) })
                            .id(shell)
                        }
                    }
                }
                .onChange(of: front) { _, front in
                    withAnimation { reader.scrollTo(front) }
                }
            }
            Button(action: open) {
                Image(systemName: "plus")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("New shell")
            .disabled(!canOpenMore)
            .help(canOpenMore
                  ? "New shell"
                  : "This agent's machine runs an older helper that holds one shell per agent.")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// One tab. The whole tab is the button that brings it forward; the close mark shows
/// on the front tab and under the pointer.
private struct ShellTab: View {
    let title: String
    let isFront: Bool
    let canClose: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 160)
                    .appText(.supporting)
                    .foregroundStyle(isFront ? .primary : .secondary)
                if canClose {
                    // Room is kept for the mark whether or not it shows, so tabs do
                    // not shift under the pointer.
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .appText(.fine)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .opacity(isFront || isHovered ? 1 : 0)
                    // A hidden mark is not a target: on a touch screen there is no
                    // pointer to show it first, so the tab is brought forward instead.
                    .allowsHitTesting(isFront || isHovered)
                    .help("Close this shell")
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, canClose ? 6 : 10)
            .padding(.vertical, 4)
            .background(isFront ? Paper.wash : (isHovered ? Paper.well : .clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        // The mark is inside the tab's button, where accessibility cannot reach it on
        // its own, so closing is offered on the tab as well.
        .accessibilityAction(named: "Close") { if canClose { close() } }
    }
}
