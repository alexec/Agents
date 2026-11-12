import AgentsKitCore
import SwiftUI

/// Undo after Archive (#1534): "Archived “Fix the parser”" with Undo, a success toast with
/// Undo (#4737) for `ArchiveUndo.seconds`, then gone. Undo is Unarchive. VoiceOver is told that
/// Undo is there, and the seconds wait while VoiceOver is on, while the toast has its focus,
/// or while the pointer is on it (#1676); `Toast` does that.
struct ArchiveUndoStrip: View {
    let undo: ArchiveUndo
    let perform: () -> Void
    let dismiss: () -> Void

    var body: some View {
        Toast(tone: .success, text: undo.line, id: undo.id, undo: true,
              announcement: undo.announcement, dismiss: dismiss) {
            Button(ArchiveUndo.undoLabel, action: perform)
                #if os(iOS)
                // ⌘Z from an iPad's keyboard while the toast shows (#1676). The Mac has
                // Session ▸ Undo Archive for it.
                .keyboardShortcut("z")
                #endif
        }
        .accessibilityAction(named: ArchiveUndo.undoLabel, perform)
    }
}

/// Undo after Unarchive, Rename, the labels, Mute or Later (#4793): the same toast as
/// Archive's, with the line `SessionUndo` says. Undo sends the inverse.
struct SessionUndoStrip: View {
    let undo: SessionUndo
    let perform: () -> Void
    let dismiss: () -> Void

    var body: some View {
        Toast(tone: .success, text: undo.line, id: undo.id, undo: true,
              announcement: undo.announcement, dismiss: dismiss) {
            Button(ArchiveUndo.undoLabel, action: perform)
                #if os(iOS)
                // ⌘Z from an iPad's keyboard while the toast shows. The Mac has the
                // Session menu's Undo item for it.
                .keyboardShortcut("z")
                #endif
        }
        .accessibilityAction(named: ArchiveUndo.undoLabel, perform)
    }
}
