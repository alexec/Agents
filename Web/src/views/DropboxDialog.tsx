// Put Files in Drop Box… (#231), from a folder row's menu: a folder inside the folder's
// `.agents/dropbox/`, if any, then files chosen from this computer. A file dropped on a folder's
// or a session's row goes to the drop box's top without asking, as the window's drop does, and
// a note under the row says where it went (#934).
import { signal, useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { Store } from "../model/store";
import { Modal } from "./Modal";

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

/** The folder's name as its folder says it, for the note under a row a drop went in by. */
export function dropboxName(folder: string): string {
  let path = folder;
  try {
    path = decodeURIComponent(new URL(folder).pathname);
  } catch { /* a plain path already */ }
  return path.replace(/\/+$/, "").split("/").pop() || path;
}

/** The note a drop leaves (#934), as the window's: "Put 2 files in work’s drop box". */
export function dropboxNote(count: number, name: string): string {
  return `Put ${count === 1 ? "1 file" : `${count} files`} in ${name}\u2019s drop box`;
}

/** How long that note stays under the row. */
const noteSeconds = 4;

/**
 * A row taking files dragged onto it (#231): into the folder's drop box, at its top. Anything
 * else dragged over the row is left alone. `targeted` lights the row while files are over it;
 * `note` says for a moment where the files went once they are in (#934), as a session's row
 * sends them to its folder and not to the chat.
 */
export function useDropboxDrop(store: Store, host: string, folder: string, down: boolean) {
  const over = useSignal(false);
  const note = useSignal<string | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => () => clearTimeout(timer.current), []);
  return {
    targeted: over.value,
    note: note.value,
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
        const files = Array.from(e.dataTransfer?.files ?? []);
        void store.putInDropbox(host, folder, "", files).then((sent) => {
          // One that could not go is the store's problem, said already.
          if (sent.length === 0 || sent.length < files.length) return;
          note.value = dropboxNote(sent.length, dropboxName(folder));
          clearTimeout(timer.current);
          timer.current = setTimeout(() => (note.value = null), noteSeconds * 1000);
        });
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
