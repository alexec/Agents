// What a folder's merged pull requests say of their cost (#2352), as the window's Folder
// Settings ▸ General ▸ Cost on pull requests. Off is the default.
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { FolderSummary, PRCostComment } from "../protocol/generated";
import { describe } from "../model/errors";
import { prCostCommentChoices, prCostCommentHelp, prCostCommentTitle, prCostCommentWords } from "../model/prCostComment";
import { Modal } from "./Modal";

export function PRCostCommentModal({ store, host, folder, summary, close }: {
  store: Store; host: string; folder: string; summary: FolderSummary; close: () => void;
}) {
  const problem = useSignal<string | null>(null);
  const busy = useSignal(false);
  const current = summary.folder.prCostComment ?? "off";
  const choose = async (choice: PRCostComment) => {
    if (choice === current) return;
    busy.value = true;
    try {
      await store.setFolderPRCostComment(host, folder, choice);
      problem.value = null;
    } catch (error) {
      problem.value = describe(error);
    } finally {
      busy.value = false;
    }
  };
  return (
    <Modal label={prCostCommentTitle} close={close}>
      <form method="dialog" class="sheet-body" onSubmit={(e) => { e.preventDefault(); close(); }}>
        <h2>{prCostCommentTitle}</h2>
        <p class="sheet-note">{summary.name}</p>
        <select aria-label={prCostCommentTitle} disabled={busy.value} value={current}
          onChange={(e) => void choose((e.currentTarget as HTMLSelectElement).value as PRCostComment)}>
          {prCostCommentChoices.map((c) => (
            <option key={c} value={c}>{c === "off" ? `${prCostCommentWords[c]} (default)` : prCostCommentWords[c]}</option>
          ))}
        </select>
        {problem.value && <p class="sheet-note failure" role="alert">{problem.value}</p>}
        <p class="sheet-note">{prCostCommentHelp} Saved in .agents/folder.json.</p>
        <div class="sheet-actions">
          <button type="submit" class="prominent">Done</button>
        </div>
      </form>
    </Modal>
  );
}
