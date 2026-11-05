// What a turn changed, at its end (#3437): the files, and Undo These Changes, which puts them back as they were before
// the turn. A file that changed again after the turn is asked about first. The window's is
// Shared/UI/Chat/TurnChangesCard.swift.
import { useContext } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { TurnChanges, TurnUndo } from "../../protocol/generated";
import { cannotUndoWords, changedTitle, confirmMessage, confirmTitle, moreWords, onlyReported, stateMark, stateWord, undoHelp,
  undoing, undoneWords, undoRefusal, undoTitle } from "../../model/turnChanges";
import { CallActionsContext } from "./Rows";

export function TurnChangesCard({ changes }: { changes: TurnChanges }) {
  const undoTurn = useContext(CallActionsContext)?.undoTurn;
  // Undone here, before the turnUndone entry comes back.
  const undone = useSignal<TurnUndo | null>(null);
  const working = useSignal(false);
  const problem = useSignal<string | null>(null);
  const done = changes.undone ?? undone.value;
  const run = async (undo: NonNullable<typeof undoTurn>) => {
    working.value = true;
    try {
      let result = await undo(changes.turn, false);
      if (result.changedSince.length > 0) {
        if (!window.confirm(`${confirmTitle}\n\n${confirmMessage(result.changedSince)}`)) return;
        result = await undo(changes.turn, true);
      }
      undone.value = { turn: changes.turn, putBack: result.putBack };
      problem.value = null;
    } catch (error) {
      problem.value = undoRefusal(error);
    } finally {
      working.value = false;
    }
  };
  return (
    <div class="note turn-changes">
      <p class="strong">{changedTitle(changes)}</p>
      <ul class="turn-files small">
        {changes.files.map((file) => (
          <li key={file.path} title={file.path}>
            <span class="quiet" aria-label={stateWord(file.state)}>{stateMark(file.state)}</span> {file.relativePath ?? file.path}
          </li>
        ))}
        {(changes.more ?? 0) > 0 && <li class="quiet">{moreWords(changes.more!)}</li>}
      </ul>
      {changes.onlyReported && <p class="quiet small">{onlyReported}</p>}
      {changes.cannotUndo && changes.cannotUndo.length > 0 && <p class="quiet small">⚠︎ {cannotUndoWords(changes.cannotUndo)}</p>}
      {done && <p class="quiet small">↩︎ {undoneWords(done)}</p>}
      {problem.value && <p class="failure small" role="alert">{problem.value}</p>}
      {!done && changes.files.length > 0 && undoTurn && (
        <p class="answers">
          <button title={undoHelp} disabled={working.value} onClick={() => void run(undoTurn)}>{working.value ? undoing : undoTitle}</button>
        </p>
      )}
    </div>
  );
}
