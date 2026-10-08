// Put Files in Drop Box… (#231), from a project row's menu: a folder inside the project's
// `.agents/dropbox/`, if any, then files chosen from this computer. A file dropped on a project's
// or a session's row goes to the drop box's top without asking, as the window's drop does.
import { signal, useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import { Modal } from "./NewProject";

type Filling = { host: string; folder: string; label: string };

/** The drop box being filled now, if any. */
const filling = signal<Filling | null>(null);

export function putFilesInDropbox(host: string, folder: string, label: string): void {
  filling.value = { host, folder, label };
}

/** Whether a drag over a row carries files, which only then is a drop box drop. */
export function carriesFiles(event: DragEvent): boolean {
  return Array.from(event.dataTransfer?.types ?? []).includes("Files");
}

/**
 * A row taking files dragged onto it (#231): into the project's drop box, at its top. Anything
 * else dragged over the row is left alone. `targeted` lights the row while files are over it.
 */
export function useDropboxDrop(store: Store, host: string, folder: string, down: boolean) {
  const over = useSignal(false);
  return {
    targeted: over.value,
    props: {
      onDragOver: (e: DragEvent) => {
        if (down || !carriesFiles(e)) return;
        e.preventDefault();
        if (e.dataTransfer) e.dataTransfer.dropEffect = "copy";
        over.value = true;
      },
      onDragLeave: () => (over.value = false),
      onDrop: (e: DragEvent) => {
        over.value = false;
        if (down || !carriesFiles(e)) return;
        e.preventDefault();
        void store.putInDropbox(host, folder, "", Array.from(e.dataTransfer?.files ?? []));
      },
    },
  };
}

/** Drawn once, by the columns. */
export function DropboxDialog({ store }: { store: Store }) {
  const open = filling.value;
  if (!open) return null;
  return <FillDropbox key={`${open.host}|${open.folder}`} store={store} {...open} close={() => (filling.value = null)} />;
}

function FillDropbox({ store, host, folder, label, close }: Filling & { store: Store; close: () => void }) {
  const subfolder = useSignal("");
  const files = useSignal<File[]>([]);
  const sending = useSignal(false);
  const send = async () => {
    sending.value = true;
    const sent = await store.putInDropbox(host, folder, subfolder.value, files.value);
    sending.value = false;
    if (sent.length === files.value.length) close();
  };
  return (
    <Modal label={`Put files in ${label}'s drop box`} close={close}>
      <form method="dialog" class="sheet-body" onSubmit={(e) => { e.preventDefault(); void send(); }}>
        <h2>Put files in {label}’s drop box</h2>
        <input type="text" aria-label="Folder in the drop box" placeholder="Folder (optional), such as review"
          value={subfolder.value} spellcheck={false}
          onInput={(e) => (subfolder.value = (e.currentTarget as HTMLInputElement).value)} />
        <input type="file" multiple aria-label="Files"
          onChange={(e) => (files.value = Array.from((e.currentTarget as HTMLInputElement).files ?? []))} />
        <p class="sheet-note">
          Into .agents/dropbox/ in {label}, where a workflow on dropbox.file_added picks them up. Up to 900 KB
          each; a file with the same name replaces the one there.
        </p>
        <div class="sheet-actions">
          <button type="button" onClick={close}>Cancel</button>
          <button type="submit" class="prominent" disabled={files.value.length === 0 || sending.value}>
            {sending.value ? "Sending…" : "Put in Drop Box"}
          </button>
        </div>
      </form>
    </Modal>
  );
}
