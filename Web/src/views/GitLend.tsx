// A host's git asking to use a Mac's git access (#1122), the window's alert: Allow or Don’t
// Allow, for that host and git server. Any client may answer; the control plane takes the first.
import type { Store } from "../model/store";
import { gitLendWords } from "../model/gitLending";
import { Modal } from "./Modal";

export function GitLendDialog({ store }: { store: Store }) {
  const ask = store.gitLendAsk;
  if (!ask) return null;
  const no = () => void store.answerGitLend(ask, false);
  return (
    <Modal key={`${ask.host} ${ask.server}`} label={gitLendWords.title(ask)} close={no}>
      <form method="dialog" class="sheet-body" onSubmit={(e) => { e.preventDefault(); void store.answerGitLend(ask, true); }}>
        <h2>{gitLendWords.title(ask)}</h2>
        <p class="sheet-note">{gitLendWords.message(ask)}</p>
        <div class="sheet-actions">
          <button type="button" onClick={no}>Don’t Allow</button>
          <button type="submit" class="prominent" autofocus>Allow</button>
        </div>
      </form>
    </Modal>
  );
}
