import AgentsKitCore
import SwiftUI

/// The scene's one toast (#4737), as the window's `WindowToast`: the result of something the
/// person did outside a sheet. A failure ("Could not finish that") stays until it is closed; Undo after Archive (#1534) goes after
/// `ToastTime.undo`. One at a time: a new one replaces the last.
///
/// It was the "That did not work" alert before. An alert is now only for a choice that blocks
/// the work (a host's git asking, a folder that has gone). A machine the provider would not
/// make opens New Machine again with its reason (#4634), so it is not a toast.
enum RemoteToast: Identifiable, Equatable {
    case problem(String, UUID)
    case archived(ArchiveUndo)

    var id: String {
        switch self {
        case .problem(_, let id): "problem-\(id)"
        case .archived(let undo): "archived-\(undo.id)"
        }
    }

    /// The words say what happened, then what to do.
    var text: String {
        switch self {
        case .problem(let text, _): "Could not finish that. \(text)"
        case .archived(let undo): undo.line
        }
    }

    /// Closed, by its button or its time. What the model has moved on from is not the
    /// model's to forget again.
    @MainActor
    func closed(in model: RemoteModel) {
        switch self {
        case .problem(let text, _): if model.problem == text { model.dismissProblem() }
        case .archived(let undo): model.dismissArchiveUndo(undo)
        }
    }
}

/// How far the scene's toast floats above the foot of the screen: the prompt bar's height,
/// so a toast is over neither the bar nor what is typed in it. The bar is in a navigation
/// column, which a preference does not leave, so it says its height here
/// (`liftsRemoteToasts()`).
@MainActor @Observable
final class RemoteToastLift {
    /// Each bar's height, by the bar: a split view can keep a bar that is not in view, and
    /// one that goes must not take the other's lift with it.
    var heights: [UUID: CGFloat] = [:]
    var height: CGFloat { heights.values.max() ?? 0 }
}

/// Floats the scene's toast at the bottom centre, above the prompt bar. The toast is held
/// here, as the window's is: a reconnect that clears the model's problem does not take a
/// failure away before the person has read it.
struct RemoteToasts: ViewModifier {
    @Environment(RemoteModel.self) private var model
    @State private var toast: RemoteToast?
    @State private var lift = RemoteToastLift()

    func body(content: Content) -> some View {
        content
            .environment(lift)
            .overlay(alignment: .bottom) {
                if let toast {
                    view(of: toast)
                        .padding(.horizontal, 16)
                        .padding(.bottom, lift.height + 12)
                        .id(toast.id)
                }
            }
            .animation(ResponseMotion.response, value: toast?.id)
            .onChange(of: model.problem, initial: true) { _, problem in
                if let problem { show(.problem(problem, UUID())) }
            }
            .onChange(of: model.archiveUndo?.id, initial: true) {
                if let undo = model.archiveUndo {
                    show(.archived(undo))
                } else if case .archived = toast {
                    // Undone, from the toast or ⌘Z.
                    toast = nil
                }
            }
    }

    /// A new toast replaces the last, and the model forgets the one it replaced, so the same
    /// failure again shows again.
    private func show(_ next: RemoteToast) {
        let last = toast
        toast = next
        last?.closed(in: model)
    }

    private func close(_ shown: RemoteToast) {
        if toast == shown { toast = nil }
        shown.closed(in: model)
    }

    @ViewBuilder
    private func view(of shown: RemoteToast) -> some View {
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

extension View {
    /// This view is at the foot of the screen, under where the scene's toast floats.
    func liftsRemoteToasts() -> some View {
        modifier(LiftsRemoteToasts())
    }
}

private struct LiftsRemoteToasts: ViewModifier {
    /// None in a scene of its own, which has no toast.
    @Environment(RemoteToastLift.self) private var lift: RemoteToastLift?
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { lift?.heights[id] = $0 }
            .onDisappear { lift?.heights[id] = nil }
    }
}
