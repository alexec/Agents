import AgentsKitCore
import SwiftUI

/// What a turn changed, at its end (#3437): the files, and Undo These Changes, which puts
/// them back as they were before the turn. A file that changed again after the turn is
/// asked about first. The page draws the same card in TurnChangesCard.tsx.
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
        VStack(alignment: .leading, spacing: 8) {
            Label(TurnChangesWords.title(changes), icon: TurnChangesWords.symbol)
                .appText(.reading).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(changes.files) { file in
                    Label {
                        Text(file.shown).appText(.fine).lineLimit(1).truncationMode(.middle)
                    } icon: {
                        Image(icon: TurnChangesWords.stateSymbol(file.state)).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("\(TurnChangesWords.stateWord(file.state)) \(file.shown)")
                }
                if let more = changes.more, more > 0 {
                    Text(TurnChangesWords.more(more)).appText(.fine).foregroundStyle(.secondary)
                }
            }
            if changes.onlyReported == true {
                Text(TurnChangesWords.onlyReported)
                    .appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let cannot = changes.cannotUndo, !cannot.isEmpty {
                Label(TurnChangesWords.cannotUndo(cannot), icon: "exclamationmark.triangle")
                    .appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let done {
                Label(TurnChangesWords.undone(done), icon: "arrow.uturn.backward")
                    .appText(.fine).foregroundStyle(.secondary)
            }
            if let problem {
                Text(problem).appText(.fine).tinted(.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if done == nil, !changes.files.isEmpty, let undo = actions.undoTurn {
                HStack {
                    Spacer()
                    Button(working ? TurnChangesWords.undoing : TurnChangesWords.undo) {
                        Task { await run(undo, confirmed: false) }
                    }
                    .buttonStyle(.paper)
                    .help(TurnChangesWords.undoHelp)
                    .disabled(working)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperWell(in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
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
