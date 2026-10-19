import AgentsKitCore
import SwiftUI

/// Undo after Archive (#1534): "Archived “Fix the parser”" with Undo, at the foot of the list
/// for `ArchiveUndo.seconds`, then gone. Undo is Unarchive.
struct ArchiveUndoStrip: View {
    let undo: ArchiveUndo
    let perform: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(undo.line)
                .appText(.supporting)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(ArchiveUndo.undoLabel, action: perform)
                .appText(.supporting)
                .buttonStyle(.borderless)
                #if os(iOS)
                .frame(minHeight: 44)
                #endif
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Opaque: the list runs on under it.
        .background(Paper.ground, in: RoundedRectangle(cornerRadius: 10))
        .paperRaised(in: RoundedRectangle(cornerRadius: 10))
        .padding(8)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: ArchiveUndo.undoLabel, perform)
        .task(id: undo.id) {
            try? await Task.sleep(for: .seconds(ArchiveUndo.seconds))
            if !Task.isCancelled { dismiss() }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
