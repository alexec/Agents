import AgentsKitCore
import SwiftUI

/// Undo after Archive (#1534): "Archived “Fix the parser”" with Undo, at the foot of the list
/// for `ArchiveUndo.seconds`, then gone. Undo is Unarchive. VoiceOver is told that Undo is
/// there, and the seconds wait while VoiceOver is on, while the strip has its focus, or while
/// the pointer is on it (#1676).
struct ArchiveUndoStrip: View {
    let undo: ArchiveUndo
    let perform: () -> Void
    let dismiss: () -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @AccessibilityFocusState private var focused: Bool
    @State private var hovering = false

    /// Whether the seconds wait.
    private var held: Bool { voiceOver || focused || hovering }

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
                // ⌘Z from an iPad's keyboard while the strip shows (#1676). The Mac has
                // Session ▸ Undo Archive for it.
                .keyboardShortcut("z")
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
        .accessibilityFocused($focused)
        .onHover { hovering = $0 }
        .task(id: undo.id) {
            AccessibilityNotification.Announcement(undo.announcement).post()
        }
        // The seconds start again when nothing holds the strip.
        .task(id: Hold(id: undo.id, held: held)) {
            guard !held else { return }
            try? await Task.sleep(for: .seconds(ArchiveUndo.seconds))
            if !Task.isCancelled { dismiss() }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct Hold: Equatable {
    let id: UUID
    let held: Bool
}
