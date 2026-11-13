// What a turn changed, at its end (#3437), as an Object card (#5035): the files by name, a click that opens them in
// Changes, and Undo These Changes in its ⋯, which puts them back as they were before the turn. A file that changed
// again after the turn is asked about first. The window's is
// Shared/UI/Chat/TurnChangesCard.swift.
import { useContext } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { TurnChanges, TurnUndo } from "../../protocol/generated";
import { cannotUndoWords, changedCount, changedTitle, confirmMessage, confirmTitle, fileNames, onlyReported, openHelp, undoHelp,
  undoing, undoneWords, undoRefusal, undoTitle } from "../../model/turnChanges";
import { ObjectCard } from "./ObjectCard";
import { CallActionsContext } from "./Rows";
import { ask } from "../MessageKinds";

export function TurnChangesCard({ changes }: { changes: TurnChanges }) {
  const actions = useContext(CallActionsContext);
  const undoTurn = actions?.undoTurn;
  const showChanges = actions?.showChanges;
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
        if (!await ask(`${confirmTitle}\n\n${confirmMessage(result.changedSince)}`)) return;
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
  // A click opens Changes (#5035): at the file when it is one, else at its list.
  const one = changedCount(changes) === 1 ? changes.files[0]?.path ?? null : null;
  const open = showChanges && changes.files.length > 0 ? () => showChanges(one) : undefined;
  const notes = [
    changes.onlyReported && <p key="r">{onlyReported}</p>,
    changes.cannotUndo && changes.cannotUndo.length > 0 && <p key="c">⚠︎ {cannotUndoWords(changes.cannotUndo)}</p>,
    working.value && <p key="w">{undoing}</p>,
    done && <p key="d">↩︎ {undoneWords(done)}</p>,
    problem.value && <p key="p" class="failure" role="alert">{problem.value}</p>,
  ].filter(Boolean);
  return (
    <ObjectCard icon="square-pen" title={changedTitle(changes)} detail={fileNames(changes)} open={open} openTitle={openHelp}
      more={!done && changes.files.length > 0 && undoTurn
        ? [{ label: undoTitle, title: undoHelp, disabled: working.value, run: () => void run(undoTurn) }] : []}
      notes={notes.length > 0 ? <div class="object-card-notes">{notes}</div> : undefined} />
  );
}
