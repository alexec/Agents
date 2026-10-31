// Console ▸ Projects (#2671, specs/2317-projects US6): every project in the organisation, its owner and
// its folders on each machine, with Rename… and Remove for its owner or an admin (projects/set,
// projects/remove). Web only, as the Console is (#1804); a folder's own project is chosen in its menu.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { Project } from "../protocol/generated";
import { failedWords } from "../model/console";
import { describe } from "../model/errors";
import { hostLabel } from "./NewFolder";
import { projectFolders, projectOwner, projectsFoot, projectTaken, projectWords, removeQuestion, removeRefusal } from "../model/projects";
import { DataTable } from "./DataTable";

export function ProjectsPage({ store, down }: { store: Store; down: boolean }) {
  const projects = useSignal<Project[] | null>(null);
  const problem = useSignal<string | null>(null);
  const renaming = useSignal<Project | null>(null);
  const name = useSignal("");
  const busy = useSignal(false);
  const load = async () => {
    try {
      projects.value = (await store.link.call("projects/list", {})).projects;
      problem.value = null;
    } catch (error) {
      problem.value = failedWords(error);
    }
  };
  // Again on each control/projectsChanged, and when a machine joins or leaves.
  const changes = store.projectsChanges.value;
  const hosts = store.hosts.value;
  useEffect(() => { if (!down) void load(); }, [down, changes, hosts]);
  const people = store.people.value?.people ?? [];
  const act = async (run: () => Promise<unknown>) => {
    busy.value = true;
    try {
      await run();
      problem.value = null;
    } catch (error) {
      problem.value = describe(error);
    } finally {
      busy.value = false;
    }
    await load();
  };
  const rename = (project: Project) => {
    const trimmed = name.value.trim();
    if (!trimmed) return;
    void act(async () => {
      await store.link.call("projects/set", { id: project.id, name: trimmed });
      renaming.value = null;
    });
  };
  const remove = (project: Project) => {
    if (!window.confirm(removeQuestion(project))) return;
    void act(() => store.link.call("projects/remove", { id: project.id }));
  };
  const list = projects.value;
  return (
    <div class="console-projects">
      {problem.value && <p class="hint" role="alert">{problem.value}</p>}
      {!list && !problem.value && <p class="hint">Loading…</p>}
      {list && (list.length === 0 ? <p class="hint">No projects yet. Each folder added makes one of its own name.</p> : (
        <DataTable id="projects" label="Projects" rows={list} rowKey={(p) => p.id} order={{ column: "name", dir: "asc" }}
          empty="No projects yet." columns={[
            { id: "name", title: "Project", sort: (p) => p.name, cell: (project) => (
              <>
                {renaming.value?.id === project.id ? (
                  <form onSubmit={(e) => { e.preventDefault(); rename(project); }}>
                    <input type="text" aria-label={projectWords.namePrompt} value={name.value} autofocus autocomplete="off"
                      onInput={(e) => (name.value = (e.currentTarget as HTMLInputElement).value)} />
                    {projectTaken(name.value, list, project.id) && (
                      <p class="small attention">There is already a project called {name.value.trim()}.</p>
                    )}
                  </form>
                ) : <span class="strong">{project.name}</span>}
                <br /><span class="quiet small">{project.id}</span>
              </>
            ) },
            { id: "owner", title: "Owner", sort: (p) => projectOwner(p.owner, people), cell: (p) => projectOwner(p.owner, people) },
            { id: "folders", title: "Folders", first: "desc", sort: (p) => p.folders.length, cell: (project) => (
              project.folders.length === 0 ? <span class="quiet">None</span> : (
                <ul>
                  {projectFolders(project, (id) => hostLabel(store, id)).map(({ machine, folder }) => (
                    <li key={`${folder.machine} ${folder.folder}`} title={folder.folder}>
                      {folder.name} <span class="quiet small">on {machine}</span>
                    </li>
                  ))}
                </ul>
              )
            ) },
            { id: "actions", title: "", class: "actions", cell: (project) => {
              const refusal = removeRefusal(project);
              return renaming.value?.id === project.id ? (
                <>
                  <button type="button" disabled={busy.value} onClick={() => (renaming.value = null)}>Cancel</button>
                  <button type="button" class="prominent" disabled={busy.value || !name.value.trim()}
                    onClick={() => rename(project)}>Save</button>
                </>
              ) : project.mayChange && (
                <>
                  <button type="button" disabled={busy.value || down}
                    onClick={() => { name.value = project.name; renaming.value = project; }}>{projectWords.rename}</button>
                  <button type="button" disabled={busy.value || down || refusal !== null} title={refusal ?? undefined}
                    onClick={() => remove(project)}>{projectWords.remove}</button>
                </>
              );
            } },
          ]} />
      ))}
      <p class="hint">{projectsFoot}</p>
    </div>
  );
}
