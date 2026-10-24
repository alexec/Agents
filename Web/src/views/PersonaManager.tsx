import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { PersonaFile } from "../protocol/generated";
import type { Store } from "../model/store";
import { Modal } from "./Modal";

/** Raw Markdown keeps front matter fields this version of the app does not know. */
export function PersonaManager({ store, host, folder, close, saved }: {
  store: Store; host: string; folder: string; close: () => void; saved: () => void;
}) {
  const origin = useSignal<"project" | "personal">("project");
  const files = useSignal<PersonaFile[]>([]);
  const selected = useSignal<string | null>(null);
  const id = useSignal("");
  const content = useSignal("");
  const busy = useSignal(false);
  const problem = useSignal<string | null>(null);

  async function load(scope = origin.value) {
    problem.value = null;
    const listed = await store.personaFiles(host, folder, scope);
    if (!listed) { problem.value = "Personas could not be loaded."; return; }
    files.value = listed;
    if (selected.value) {
      const current = listed.find((file) => file.id === selected.value);
      if (current) content.value = current.content;
      else { selected.value = null; id.value = ""; content.value = ""; }
    }
  }
  useEffect(() => { void load(); }, []);

  function pick(file: PersonaFile) {
    selected.value = file.id;
    id.value = file.id;
    content.value = file.content;
    problem.value = null;
  }

  async function save(remove = false) {
    const name = id.value.trim();
    if (!name) { problem.value = "Enter a persona file name."; return; }
    if (remove && !window.confirm(`Delete ${name}.md?`)) return;
    busy.value = true;
    problem.value = null;
    const ok = await store.savePersonaFile(host, folder, origin.value, name, content.value, remove);
    busy.value = false;
    if (!ok) { problem.value = remove ? "The persona could not be deleted." : "The persona could not be saved."; return; }
    selected.value = remove ? null : name;
    if (remove) { id.value = ""; content.value = ""; }
    await load();
    saved();
  }

  return (
    <Modal label="Manage personas" close={close}>
      <div class="sheet-body persona-manager">
        <h2>Personas</h2>
        <p class="sheet-note">Edit the full Markdown file. Front matter fields the app does not know stay intact.</p>
        <label>Storage scope
          <select value={origin.value} disabled={busy.value} onChange={(event) => {
            origin.value = (event.currentTarget as HTMLSelectElement).value as "project" | "personal";
            selected.value = null; id.value = ""; content.value = "";
            void load(origin.value);
          }}>
            <option value="project">This project</option><option value="personal">Personal</option>
          </select>
        </label>
        <div class="persona-manager-list" aria-label="Persona files">
          {files.value.map((file) => <button type="button" class="pill" aria-pressed={selected.value === file.id}
            key={file.id} onClick={() => pick(file)}>{file.id}</button>)}
          <button type="button" class="pill" onClick={() => { selected.value = null; id.value = ""; content.value = ""; problem.value = null; }}>New persona</button>
        </div>
        <label>File name
          <input type="text" value={id.value} disabled={busy.value || selected.value !== null}
            onInput={(event) => { id.value = (event.currentTarget as HTMLInputElement).value; }} placeholder="reviewer" />
        </label>
        <label>Markdown
          <textarea value={content.value} rows={12} disabled={busy.value}
            onInput={(event) => { content.value = (event.currentTarget as HTMLTextAreaElement).value; }} />
        </label>
        {problem.value && <p class="sheet-note failure" role="alert">{problem.value}</p>}
        <div class="sheet-actions">
          {selected.value !== null && <button type="button" class="pill" disabled={busy.value} onClick={() => void save(true)}>Delete</button>}
          <button type="button" class="pill" onClick={close}>Done</button>
          <button type="button" class="pill prominent" disabled={busy.value} onClick={() => void save()}>{busy.value ? "Saving…" : "Save"}</button>
        </div>
      </div>
    </Modal>
  );
}
