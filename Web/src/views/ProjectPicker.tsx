// A folder's Project (#2317), as the window's Folder Settings ▸ General ▸ Project and the
// Remote's folder menu (Shared/UI/ProjectPicker.swift): the organisation's projects to put the
// folder in, New Project… and, for the owner or an admin, Rename Project….
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { Store } from "../model/store";
import type { FolderSummary, Project } from "../protocol/generated";
import { describe } from "../model/errors";
import { projectTaken, projectWords, unknownProject } from "../model/projects";
import { Modal } from "./Modal";

export function ProjectModal({ store, host, folder, summary, close }: {
  store: Store; host: string; folder: string; summary: FolderSummary; close: () => void;
}) {
  const projects = useSignal<Project[]>([]);
  const naming = useSignal<"new" | Project | null>(null);
  const name = useSignal("");
  const problem = useSignal<string | null>(null);
  const busy = useSignal(false);
  const load = async () => {
    projects.value = (await store.link.call("projects/list", {}).catch(() => null))?.projects ?? [];
  };
  useEffect(() => { void load(); }, [summary.project]);
  const join = async (id: string) => {
    if (!id || id === summary.project) return;
    busy.value = true;
    try {
      await store.setFolderProject(host, folder, id);
      problem.value = null;
    } catch (error) {
      problem.value = describe(error);
    } finally {
      busy.value = false;
    }
  };
  const save = async () => {
    const asked = naming.value;
    const trimmed = name.value.trim();
    if (!asked || !trimmed) return;
    busy.value = true;
    try {
      if (asked === "new") {
        const made = await store.link.call("projects/set", { name: trimmed });
        naming.value = null;
        busy.value = false;
        await join(made.id);
      } else {
        await store.link.call("projects/set", { id: asked.id, name: trimmed });
        naming.value = null;
      }
    } catch (error) {
      problem.value = describe(error);
    } finally {
      busy.value = false;
    }
    await load();
  };
  const current = projects.value.find((p) => p.id === summary.project);
  const ask = (asked: "new" | Project) => {
    name.value = asked === "new" ? summary.name : asked.name;
    problem.value = null;
    naming.value = asked;
  };
  return (
    <Modal label={projectWords.title} close={close}>
      <form method="dialog" class="sheet-body" onSubmit={(e) => { e.preventDefault(); void save(); }}>
        <h2>{projectWords.title}</h2>
        <p class="sheet-note">{summary.name}</p>
        <select aria-label={projectWords.title} disabled={busy.value} value={summary.project ?? ""}
          onChange={(e) => void join((e.currentTarget as HTMLSelectElement).value)}>
          {summary.project === undefined && <option value="">None</option>}
          {summary.project !== undefined && !current && <option value={summary.project}>{unknownProject(summary.project)}</option>}
          {projects.value.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
        </select>
        {naming.value === null ? (
          <div class="sheet-actions">
            <button type="button" disabled={busy.value} onClick={() => ask("new")}>{projectWords.newProject}</button>
            {current?.mayChange && (
              <button type="button" disabled={busy.value} onClick={() => ask(current)}>{projectWords.rename}</button>
            )}
          </div>
        ) : (
          <>
            <input type="text" aria-label={projectWords.namePrompt} placeholder={projectWords.namePrompt} autofocus
              autocomplete="off" value={name.value}
              onInput={(e) => (name.value = (e.currentTarget as HTMLInputElement).value)} />
            {projectTaken(name.value, projects.value, naming.value === "new" ? undefined : naming.value.id) && (
              <p class="sheet-note">There is already a project called {name.value.trim()}.</p>
            )}
          </>
        )}
        {summary.projectProblem && <p class="sheet-note failure" role="alert">{summary.projectProblem}</p>}
        {problem.value && <p class="sheet-note failure" role="alert">{problem.value}</p>}
        <p class="sheet-note">{projectWords.explanation}</p>
        <div class="sheet-actions">
          {naming.value !== null ? (
            <>
              <button type="button" onClick={() => (naming.value = null)}>Cancel</button>
              <button type="submit" class="prominent" disabled={!name.value.trim() || busy.value}>Save</button>
            </>
          ) : (
            <button type="button" class="prominent" onClick={close}>Done</button>
          )}
        </div>
      </form>
    </Modal>
  );
}
