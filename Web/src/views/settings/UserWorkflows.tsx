// Settings ▸ Machines ▸ Workflows: files in ~/.agents/workflows on the Mac's host.
import { useEffect, useState } from "preact/hooks";
import type { Store } from "../../model/store";

export function UserWorkflowsSection({ store, down }: { store: Store; down: boolean }) {
  const host = store.macHostID.value;
  const [selectedID, setSelectedID] = useState<string | null>(null);
  const [content, setContent] = useState("");
  const [newID, setNewID] = useState("");
  const [problem, setProblem] = useState<string | null>(null);
  const workflows = store.userWorkflows(host).slice().sort((a, b) => a.workflow.name.localeCompare(b.workflow.name));
  const selected = workflows.find((workflow) => workflow.workflow.workflowID === selectedID);

  useEffect(() => { void store.loadUserWorkflows(host); }, [store, host]);
  useEffect(() => { setContent(selected?.content ?? ""); setProblem(null); }, [selectedID]);

  const add = async () => {
    const id = newID.trim();
    if (!id) return;
    if (workflows.some((workflow) => workflow.workflow.workflowID === id)) {
      setProblem("A workflow with that ID already exists. Choose another ID.");
      return;
    }
    const text = "---\non: manual\n---\n\nWrite what the agent should do.\n";
    const refusal = await store.writeUserWorkflow(host, id, text);
    setProblem(refusal);
    if (!refusal) { setNewID(""); setSelectedID(id); setContent(text); }
  };
  const save = async () => {
    if (!selected) return;
    setProblem(await store.writeUserWorkflow(host, selected.workflow.workflowID, content));
  };
  const remove = async () => {
    if (!selected || !confirm(`Delete “${selected.workflow.name}” from your workflows?`)) return;
    const deleted = await store.deleteWorkflow(host, selected);
    if (deleted) {
      await store.loadUserWorkflows(host);
      setSelectedID(null);
      setContent("");
    }
  };

  return <section aria-labelledby="settings-workflows">
    <h3 class="section-head" id="settings-workflows">Workflows</h3>
    <p class="hint">Ready-made workflows live here. Projects that use one keep their own on or off switch.</p>
    <div class="setting">
      <label htmlFor="new-workflow-id">New workflow ID</label>
      <input id="new-workflow-id" value={newID} onInput={(event) => setNewID(event.currentTarget.value)} />
      <button type="button" disabled={down || !newID.trim()} onClick={() => void add()}>Add</button>
    </div>
    <div class="setting">
      <label htmlFor="user-workflow-list">Your workflows</label>
      <select id="user-workflow-list" value={selectedID ?? ""} onChange={(event) => setSelectedID(event.currentTarget.value || null)}>
        <option value="">Choose a workflow</option>
        {workflows.map((workflow) => <option key={workflow.workflow.workflowID} value={workflow.workflow.workflowID}>{workflow.workflow.name}</option>)}
      </select>
    </div>
    {selected && <div class="setting">
      <label htmlFor="user-workflow-content">~/.agents/workflows/{selected.workflow.workflowID}.md</label>
      <textarea id="user-workflow-content" class="prompt-text" rows={16} value={content}
        onInput={(event) => setContent(event.currentTarget.value)} />
      <button type="button" disabled={down || content === (selected.content ?? "")} onClick={() => void save()}>Save</button>
      <button type="button" class="archive" disabled={down} onClick={() => void remove()}>Delete…</button>
    </div>}
    {problem && <p class="failure">{problem}</p>}
    <p class="hint">Files are shared with your machines.</p>
  </section>;
}
