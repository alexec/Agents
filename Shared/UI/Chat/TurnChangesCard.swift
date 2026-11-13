import AgentsKitCore
import SwiftUI

/// What a turn changed, at its end (#3437), as an Object card (#5035): the files by name, a
/// tap that opens them in Changes, and Undo These Changes in its ⋯, which puts them back as
/// they were before the turn. A file that changed again after the turn is asked about
/// first. The page draws the same card in TurnChangesCard.tsx.
struct TurnChangesCard: View {
    let changes: TurnChanges
    @Environment(\.chatActions) private var actions
    /// Undone here, before the turnUndone entry comes back.
    @State private var undone: TurnUndo?
    @State private var asking: [String] = []
    @State private var working = false
    @State private var problem: String?

    private var done: TurnUndo? { changes.undone ?? undone }

    var body: some View {
        ObjectCard(icon: TurnChangesWords.symbol, title: TurnChangesWords.title(changes),
                   detail: TurnChangesWords.names(changes), open: open, openHelp: TurnChangesWords.openHelp,
                   more: more) {
            if changes.onlyReported == true {
                Text(TurnChangesWords.onlyReported)
                    .appText(.fine).foregroundStyle(Paper.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let cannot = changes.cannotUndo, !cannot.isEmpty {
                Label(TurnChangesWords.cannotUndo(cannot), icon: "exclamationmark.triangle")
                    .appText(.fine).foregroundStyle(Paper.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if working {
                Text(TurnChangesWords.undoing).appText(.fine).foregroundStyle(Paper.secondary)
            }
            if let done {
                Label(TurnChangesWords.undone(done), icon: "arrow.uturn.backward")
                    .appText(.fine).foregroundStyle(Paper.secondary)
            }
            if let problem {
                Text(problem).appText(.fine).tinted(.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: ObjectCard<EmptyView, EmptyView>.width, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(TurnChangesWords.confirmTitle, isPresented: Binding(
            get: { !asking.isEmpty }, set: { if !$0 { asking = [] } }), titleVisibility: .visible) {
            Button(TurnChangesWords.confirmUndo, role: .destructive) {
                guard let undo = actions.undoTurn else { return }
                Task { await run(undo, confirmed: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(TurnChangesWords.confirmMessage(asking))
        }
    }

    /// A tap opens Changes (#5035): at the file when it is one, else at the list.
    private var open: (@MainActor () -> Void)? {
        guard let show = actions.showChanges, !changes.files.isEmpty else { return nil }
        let one = changes.count == 1 ? changes.files.first?.path : nil
        return { show(one) }
    }

    /// The ⋯: Undo These Changes, with the same question as before when a file changed since.
    private var more: [StripButton] {
        guard done == nil, !changes.files.isEmpty, let undo = actions.undoTurn else { return [] }
        return [StripButton(title: TurnChangesWords.undo, help: TurnChangesWords.undoHelp, disabled: working) {
            Task { await run(undo, confirmed: false) }
        }]
    }

    private func run(_ undo: @MainActor (UUID, Bool) async throws -> DaemonAPI.UndoTurnResult, confirmed: Bool) async {
        working = true
        defer { working = false }
        do {
            let result = try await undo(changes.turn, confirmed)
            problem = nil
            if !confirmed, !result.changedSince.isEmpty {
                asking = result.changedSince
            } else {
                undone = TurnUndo(turn: changes.turn, putBack: result.putBack)
            }
        } catch {
            problem = TurnChangesWords.refusal(error)
        }
    }
}
