import { useEffect, useState } from "preact/hooks";
import type { AgentConfigEditorFile } from "../protocol/generated";
import type { Store } from "../model/store";
import { Modal } from "./Modal";

export type AgentConfigKind = "skills" | "personas" | "workflows";
const kinds: AgentConfigKind[] = ["skills", "personas", "workflows"];
const title = (kind: AgentConfigKind) => kind.charAt(0).toUpperCase() + kind.slice(1);

function parts(content: string) {
  const end = content.startsWith("---\n") ? content.indexOf("\n---\n", 4) : -1;
  return end < 0
    ? { frontmatter: "", markdown: content, hasFrontmatter: false }
    : { frontmatter: content.slice(4, end), markdown: content.slice(end + 5), hasFrontmatter: true };
}

function whole(frontmatter: string, markdown: string, hasFrontmatter: boolean) {
  return hasFrontmatter || frontmatter !== "" ? `---\n${frontmatter}\n---\n${markdown}` : markdown;
}

/** What the editor and its dialog say when unsaved edits would be lost (#2745), as the Mac and the Remote. */
export const discardQuestion = "Discard unsaved changes? Your changes to this file have not been saved.";

/** Asks before unsaved edits are dropped; true when there are none or the person discards them. */
export const mayLeave = (unsaved: boolean, ask: (question: string) => boolean = confirm) =>
  !unsaved || ask(discardQuestion);

/** The same file controls serve personal Settings and a project's Agent Configuration. */
export function AgentConfigEditor({ store, host, folder, kind, down, onUnsaved }: {
  store: Store; host: string; folder?: string; kind: AgentConfigKind; down: boolean;
  /** Told when the open file gets or loses edits not saved, for a container that can leave the editor. */
  onUnsaved?: (unsaved: boolean) => void;
}) {
  const [files, setFiles] = useState<AgentConfigEditorFile[]>([]);
  const [selected, setSelected] = useState("");
  const [newName, setNewName] = useState("");
  const [frontmatter, setFrontmatter] = useState("");
  const [markdown, setMarkdown] = useState("");
  const [hasFrontmatter, setHasFrontmatter] = useState(false);
  const [original, setOriginal] = useState("");
  const [problem, setProblem] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const content = whole(frontmatter, markdown, hasFrontmatter);
  const dirty = selected !== "" && content !== original;
  useEffect(() => { onUnsaved?.(dirty); }, [dirty]);
  useEffect(() => () => onUnsaved?.(false), []);
  // Leaving or reloading the page drops the edits too: the browser asks first.
  useEffect(() => {
    if (!dirty) return;
    const ask = (event: BeforeUnloadEvent) => { event.preventDefault(); };
    addEventListener("beforeunload", ask);
    return () => removeEventListener("beforeunload", ask);
  }, [dirty]);

  function pick(path: string, listed: AgentConfigEditorFile[] = files) {
    const file = listed.find((item) => item.path === path);
    const parsed = parts(file?.content ?? "");
    setSelected(path);
    setFrontmatter(parsed.frontmatter);
    setMarkdown(parsed.markdown);
    setHasFrontmatter(parsed.hasFrontmatter);
    setOriginal(file?.content ?? "");
    setProblem(null);
  }

  async function reload(wanted = selected) {
    const listed = await store.agentConfigEditorFiles(host, folder, kind);
    if (!listed) { setProblem("Files could not be loaded."); return; }
    setFiles(listed);
    pick(listed.some((file) => file.path === wanted) ? wanted : listed[0]?.path ?? "", listed);
  }
  useEffect(() => { setSelected(""); void reload(""); }, [host, folder, kind]);

  async function add() {
    const name = newName.trim();
    const path = kind === "skills" ? `${name}/SKILL.md` : `${name}.md`;
    if (files.some((file) => file.path === path)) { setProblem("This file already exists."); return; }
    const text = kind === "workflows" ? "---\non: manual\n---\n\n" : `---\nname: ${name}\n---\n\n`;
    setBusy(true);
    const error = await store.saveAgentConfigEditorFile(host, folder, kind, path, text, false);
    setBusy(false);
    if (error) { setProblem(error); return; }
    setNewName("");
    await reload(path);
  }
  async function save(remove: boolean) {
    if (!selected) return;
    if (remove && !confirm(`Delete ${selected}?`)) return;
    setBusy(true);
    const error = await store.saveAgentConfigEditorFile(host, folder, kind, selected, content, remove);
    setBusy(false);
    if (error) { setProblem(error); return; }
    await reload(remove ? "" : selected);
  }

  return <div class="agent-config-editor">
    <p class="hint">{folder ? `.agents/${kind}` : `~/.agents/${kind}`}</p>
    <div class="agent-config-controls">
      <label>File
        <select value={selected} disabled={down || busy || dirty} onChange={(event) => pick(event.currentTarget.value)}>
          <option value="">Choose a file</option>
          {files.map((file) => <option key={file.path} value={file.path}>{file.path}</option>)}
        </select>
      </label>
      <label>New file name
        <input value={newName} disabled={down || busy} onInput={(event) => setNewName(event.currentTarget.value)} />
      </label>
      <button type="button" disabled={down || busy || dirty || !newName.trim()} onClick={() => void add()}>Add</button>
    </div>
    {selected ? <>
      <label>Frontmatter (YAML)
        <textarea rows={7} value={frontmatter} disabled={down || busy}
          onInput={(event) => setFrontmatter(event.currentTarget.value)} />
      </label>
      <label>Markdown
        <textarea rows={14} value={markdown} disabled={down || busy}
          onInput={(event) => setMarkdown(event.currentTarget.value)} />
      </label>
      <div class="agent-config-actions">
        <button type="button" disabled={down || busy || !dirty} onClick={() => pick(selected)}>Discard changes</button>
        <button type="button" class="archive" disabled={down || busy} onClick={() => void save(true)}>Delete…</button>
        <button type="button" class="prominent" disabled={down || busy || !dirty} onClick={() => void save(false)}>Save</button>
      </div>
    </> : <p class="hint">Add or choose a file to edit it.</p>}
    {problem && <p class="failure" role="alert">{problem}</p>}
  </div>;
}

export function AgentConfigSettingsSection({ store, down, kind }: {
  store: Store; down: boolean; kind: AgentConfigKind;
}) {
  return <section aria-label={title(kind)}>
    <h3 class="section-head">{title(kind)}</h3>
    <AgentConfigEditor store={store} host={store.macHostID.value} kind={kind} down={down} />
  </section>;
}

export const SkillsConfigSection = ({ store, down }: { store: Store; down: boolean }) =>
  <AgentConfigSettingsSection store={store} down={down} kind="skills" />;
export const PersonasConfigSection = ({ store, down }: { store: Store; down: boolean }) =>
  <AgentConfigSettingsSection store={store} down={down} kind="personas" />;
export const WorkflowsConfigSection = ({ store, down }: { store: Store; down: boolean }) =>
  <AgentConfigSettingsSection store={store} down={down} kind="workflows" />;

export function ProjectAgentConfigModal({ store, host, folder, down, close }: {
  store: Store; host: string; folder: string; down: boolean; close: () => void;
}) {
  const [kind, setKind] = useState<AgentConfigKind>("skills");
  const [unsaved, setUnsaved] = useState(false);
  const leave = (then: () => void) => { if (mayLeave(unsaved)) { setUnsaved(false); then(); } };
  return <Modal label="Agent Configuration" close={close} keep={() => !mayLeave(unsaved)}>
    <div class="sheet-body agent-config-project">
      <h2>Agent Configuration</h2>
      <div class="segmented" role="tablist" aria-label="Configuration files">
        {kinds.map((item) => <button type="button" key={item} role="tab" aria-selected={kind === item}
          class={kind === item ? "on" : ""} onClick={() => { if (item !== kind) leave(() => setKind(item)); }}>{title(item)}</button>)}
      </div>
      <AgentConfigEditor store={store} host={host} folder={folder} kind={kind} down={down} onUnsaved={setUnsaved} />
      <div class="sheet-actions"><button type="button" onClick={() => leave(close)}>Done</button></div>
    </div>
  </Modal>;
}
