// An Export… or Import Agents… on its way (#2437), as the window's and the Remote's busy sheet:
// what it is doing, how far, and Cancel. Export… and Import Agents… are off while it runs.
import type { Store } from "../model/store";
import { Modal } from "./Modal";

export function ExportImportDialog({ store }: { store: Store }) {
  const busy = store.exportImport.value;
  if (!busy) return null;
  return (
    <Modal label={busy.line} close={busy.cancel}>
      <div class="sheet-body export-import-sheet" role="status" aria-live="polite">
        <h2>{busy.line}</h2>
        {busy.fraction === null
          ? <progress aria-label={busy.line} />
          : <progress aria-label={busy.line} max={1} value={busy.fraction} />}
        <div class="sheet-actions">
          <button type="button" onClick={busy.cancel} autofocus>Cancel</button>
        </div>
      </div>
    </Modal>
  );
}
