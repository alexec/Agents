import AgentsKitCore
import SwiftUI

/// The window's one toast (#4737): the result of something the person did outside a sheet.
/// A failure ("Could not finish that") stays until it is closed; a machine the provider would
/// not make opens New Machine's sheet again with the reason instead (#4634); Undo after Archive (#1534) goes after `ToastTime.undo`. One at a time: a new
/// one replaces the last.
///
/// These were the window's alert (#101) before. An alert is now only for a choice that blocks
/// the work (`WindowAlert`).
enum WindowToast: Identifiable, Equatable {
    case problem(AlertWords)
    case archived(ArchiveUndo)

    var id: String {
        switch self {
        case .problem(let words): "problem-\(words.id)"
        case .archived(let undo): "archived-\(undo.id)"
        }
    }

    /// The words say what happened, then what to do.
    var text: String {
        switch self {
        case .problem(let words): "Could not finish that. \(words.text)"
        case .archived(let undo): undo.line
        }
    }

    /// Closed, by its button or its time. What the model has moved on from is not the
    /// model's to forget again.
    @MainActor
    func closed(in model: AppModel) {
        switch self {
        case .problem(let words): if model.problem == words.text { model.dismissProblem() }
        case .archived(let undo): model.dismissArchiveUndo(undo)
        }
    }
}

/// Floats the window's toast at the bottom centre of the pane, above the prompt bar
/// (`ToastLiftKey`). The toast is held here, as the alert was (#101): a reconnect that clears
/// the model's problem does not take a failure away before the person has read it.
struct WindowToasts: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var toast: WindowToast?
    @State private var lift: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(ToastLiftKey.self) { lift = $0 }
            .overlay(alignment: .bottom) {
                if let toast {
                    view(of: toast)
                        .padding(.horizontal, 16)
                        .padding(.bottom, lift + 12)
                        .id(toast.id)
                }
            }
            .animation(ResponseMotion.response, value: toast?.id)
            .onChange(of: model.problem, initial: true) { _, problem in
                if let problem { show(.problem(AlertWords(text: problem))) }
            }
            .onChange(of: model.archiveUndo?.id, initial: true) {
                if let undo = model.archiveUndo {
                    show(.archived(undo))
                } else if case .archived = toast {
                    // Undone, from the toast or Session ▸ Undo Archive.
                    toast = nil
                }
            }
    }

    /// A new toast replaces the last, and the model forgets the one it replaced, so the same
    /// failure again shows again.
    private func show(_ next: WindowToast) {
        guard toast != next else { return }
        let last = toast
        toast = next
        last?.closed(in: model)
    }

    private func close(_ shown: WindowToast) {
        if toast == shown { toast = nil }
        shown.closed(in: model)
    }

    @ViewBuilder
    private func view(of shown: WindowToast) -> some View {
        switch shown {
        case .archived(let undo):
            ArchiveUndoStrip(undo: undo,
                             perform: { Task { await model.undoArchive() } },
                             dismiss: { close(shown) })
        case .problem:
            Toast(tone: .failure, text: shown.text, id: shown.id, dismiss: { close(shown) })
        }
    }
}
