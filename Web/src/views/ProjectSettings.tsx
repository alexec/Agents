// Project Settings and Folder Settings (#3280, specs/3273-project-unit), as the window's
// App/Sources/Folders/ProjectSettingsSheet.swift and FolderSettingsSheet.swift. Project Settings is
// what every folder of the project shares, kept in this folder's .agents and committed; Folder
// Settings is one folder's alone: where it is, its project, and its disk space lines.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { Store } from "../model/store";
import type { FolderSummary, HelperLimits, PRCostComment, Project } from "../protocol/generated";
import { Capability } from "../protocol/capabilities.generated";
import { describe } from "../model/errors";
import { go } from "../route";
import { policyItem } from "../model/policyLayers";
import { prCostCommentChoices, prCostCommentHelp, prCostCommentTitle, prCostCommentWords } from "../model/prCostComment";
import {
  diskChoices, diskDefaults, folderPanes, folderPathOf, helperDefaults, projectPanes, projectSettingsWords, queuedChoices,
  withDiskLine, withLimit, writtenIn, type FolderPane, type ProjectPane,
} from "../model/projectSettings";
import { Modal } from "./Modal";
import { ProjectModal } from "./ProjectPicker";
import { ProjectAgentConfigModal } from "./AgentConfigEditor";
import { addFolderOn, hostLabel } from "./NewFolder";

type Props = { store: Store; host: string; folder: string; summary: FolderSummary; down: boolean; close: () => void };

const machineName = hostLabel;

/** What a change could not do, said under the pane. */
function useSaving() {
  const problem = useSignal<string | null>(null);
  const busy = useSignal(false);
  const save = async (change: () => Promise<void>) => {
    busy.value = true;
    try {
      await change();
      problem.value = null;
    } catch (error) {
      problem.value = describe(error);
    } finally {
      busy.value = false;
    }
  };
  return { problem, busy, save };
}

export function ProjectSettingsModal({ store, host, folder, summary, down, close, openFolder }: Props & {
  /** Folder Settings of one of the project's folders, in place of this dialog. */
  openFolder: (host: string, folder: string) => void;
}) {
  const pane = useSignal<ProjectPane>("general");
  const project = useSignal<Project | undefined>(undefined);
  // The owner's name, from people/list; undefined when it could not be read.
  const owner = useSignal<string | undefined>(undefined);
  const config = useSignal(false);
  const { problem, busy, save } = useSaving();
  useEffect(() => {
    if (summary.project === undefined) { project.value = undefined; return; }
    void store.link.call("projects/list", {})
      .then(async (list) => {
        project.value = list.projects.find((p) => p.id === summary.project);
        const people = await store.link.call("people/list", {}).catch(() => undefined);
        owner.value = people?.people.find((p) => p.id === project.value?.owner)?.name;
      })
      .catch(() => { project.value = undefined; });
  }, [summary.project]);
  const limits = summary.folder.helperLimits;
  const setLimits = (next: HelperLimits) => save(() => store.setFolderHelperLimits(host, folder, next));
  const note = <p class="sheet-note">{writtenIn(folderPathOf(folder), machineName(store, host))}</p>;
  const off = down || busy.value;

  // The window's own folders of the project first, then what the control plane says of the others.
  const mine = summary.project === undefined ? [{ host, summary }]
    : Object.entries(store.folders.value).flatMap(([h, list]) => (list ?? [])
      .filter((s) => s.project === summary.project && s.folder.archivedAt === undefined).map((s) => ({ host: h, summary: s })));
  const others = (project.value?.folders ?? []).filter((f) => !mine.some((m) => m.host === f.machine
    && folderPathOf(m.summary.folder.folder) === folderPathOf(f.folder)));
  const otherMachines = store.hosts.value.filter((h) => store.hostIsOnline(h.id) && h.relay === undefined
    && !mine.some((m) => m.host === h.id) && !others.some((f) => f.machine === h.id));

  const general = <>
    <dl class="settings-grid">
      <dt>Name</dt><dd>{project.value?.name ?? summary.name}</dd>
      {owner.value && <><dt>Owner</dt><dd>{owner.value}</dd></>}
      <dt>Folders</dt>
      <dd>
        <ul class="project-folders">
          {mine.map((m) => (
            <li key={`${m.host}|${m.summary.folder.folder}`}>
              <span class="machine">{machineName(store, m.host)}</span>
              <span class="path" title={folderPathOf(m.summary.folder.folder)}>{folderPathOf(m.summary.folder.folder)}</span>
              <span class="sheet-note">{!m.summary.exists ? "missing" : store.hostIsOnline(m.host) ? "online" : "offline"}</span>
              <button type="button" onClick={() => openFolder(m.host, m.summary.folder.folder)}>{projectSettingsWords.folderMenuItem}</button>
            </li>
          ))}
          {others.map((f) => (
            <li key={`${f.machine}|${f.folder}`}>
              <span class="machine">{machineName(store, f.machine)}</span>
              <span class="path">{folderPathOf(f.folder)}</span>
              <span class="sheet-note">{projectSettingsWords.notConnected}</span>
            </li>
          ))}
        </ul>
        {otherMachines.length > 0 && (
          <label class="sheet-note">{projectSettingsWords.addOnAnotherMachine}{" "}
            <select aria-label={projectSettingsWords.addOnAnotherMachine} value=""
              onChange={(e) => {
                const machine = (e.currentTarget as HTMLSelectElement).value;
                if (machine) { close(); addFolderOn(machine); }
              }}>
              <option value="">Choose a machine</option>
              {otherMachines.map((h) => <option key={h.id} value={h.id}>{machineName(store, h.id)}</option>)}
            </select>
          </label>
        )}
        {summary.project === undefined && <p class="sheet-note">{projectSettingsWords.noControlPlane}</p>}
      </dd>
      {store.has(host, Capability.lineageComment1) && <>
        <dt>{prCostCommentTitle}</dt>
        <dd>
          <select aria-label={prCostCommentTitle} disabled={off} value={summary.folder.prCostComment ?? "off"}
            onChange={(e) => void save(() => store.setFolderPRCostComment(host, folder,
              (e.currentTarget as HTMLSelectElement).value as PRCostComment))}>
            {prCostCommentChoices.map((c) => (
              <option key={c} value={c}>{c === "off" ? `${prCostCommentWords[c]} (default)` : prCostCommentWords[c]}</option>
            ))}
          </select>
          <p class="sheet-note">{prCostCommentHelp} Saved in .agents/folder.json.</p>
        </dd>
      </>}
    </dl>
  </>;

  const queued = limits?.queued ?? helperDefaults.queued;
  const workAtOnce = <dl class="settings-grid">
    <dt>Helpers</dt>
    <dd>
      <p class="sheet-note">How many run and stay unarchived is set in Agents ▸ Policy, or for this project in Policy. They
        count across all the project's folders, on every machine. A lead doesn't count; the sessions it starts do.</p>
    </dd>
    <dt>Helpers queued</dt>
    <dd>
      <select aria-label="Helpers queued" disabled={off} value={String(queued)}
        onChange={(e) => void setLimits(withLimit(limits, "queued", Number((e.currentTarget as HTMLSelectElement).value),
          helperDefaults.queued))}>
        {queuedChoices(queued).map((n) => <option key={n} value={String(n)}>{n === helperDefaults.queued ? `${n} (default)` : n}</option>)}
      </select>
      <p class="sheet-note">How many more sessions that other sessions started may wait to start, oldest first, when a place
        frees. Agents can't change this. Saved in .agents/folder.json.</p>
    </dd>
    <dt>Allowance spent</dt>
    <dd>
      <Switch label="Helpers continue when the allowance is back" disabled={off} on={limits?.continueWhenBack === true}
        set={(on) => void setLimits(withLimit(limits, "continueWhenBack", on || undefined, undefined))} />
      <p class="sheet-note">A session started by a session waits for the allowance and carries on when it is back, as if
        you had chosen Continue. Off, it stops until you do.</p>
    </dd>
    <dt>Other machines</dt>
    <dd>
      <Switch label="Agents may start sessions on my other machines without asking" disabled={off}
        on={limits?.agentsMayStartOnMachines === true}
        set={(on) => void setLimits(withLimit(limits, "agentsMayStartOnMachines", on || undefined, undefined))} />
      <p class="sheet-note">On, a session here may start a session on another of your machines without asking you first.
        The new session's chat still says which session started it, and from which machine. Off, it asks you each time.</p>
    </dd>
  </dl>;

  const sessions = <dl class="settings-grid">
    <dt>Helpers archived</dt>
    <dd>
      <Switch label="Sessions may archive the sessions they started" disabled={off}
        on={limits?.agentsMayArchive ?? helperDefaults.agentsMayArchive}
        set={(on) => void setLimits(withLimit(limits, "agentsMayArchive", on, helperDefaults.agentsMayArchive))} />
      <p class="sheet-note">A session may archive only sessions it started, once their turn has ended, and never your own
        sessions. Off, it asks you instead. You can bring any of them back.</p>
    </dd>
    <dt>Pull request merged</dt>
    <dd>
      <Switch label="Archive a session when its pull request merges" disabled={off}
        on={limits?.archiveWhenMerged ?? helperDefaults.archiveWhenMerged}
        set={(on) => void setLimits(withLimit(limits, "archiveWhenMerged", on, helperDefaults.archiveWhenMerged))} />
      <p class="sheet-note">A session in a worktree is archived when the pull request from its branch merges, once its turn
        has ended and its worktree has nothing uncommitted. Any other session gets a line in its chat. This needs the github
        or gitlab connector in this folder. You can bring any of them back.</p>
    </dd>
  </dl>;

  // The Connectors page and Agents ▸ Policy are the page's own places for these; the dialog opens them.
  const elsewhere = (words: string, button: string, open: () => void) => <>
    <p class="sheet-note">{words}</p>
    <div class="sheet-actions start"><button type="button" onClick={() => { close(); open(); }}>{button}</button></div>
  </>;
  const tools = elsewhere("The Tasks, Code review and CI slots are the project's, the same in every folder of it. "
    + "Docs and Where agents run are on the same page.", "Open Connectors", () => go({ host, folder, mcp: true }));
  const policy = elsewhere("This project's own policy, kept in .agents/policy.json and committed with its code.",
    "Open Policy", () => go({ nav: "settings", section: "settings", item: policyItem(folder) }));
  const agentConfiguration = <>
    <p class="sheet-note">Instructions, skills, personas, workflows and connectors in this folder's .agents.</p>
    <div class="sheet-actions start"><button type="button" disabled={down} onClick={() => (config.value = true)}>Edit Files…</button></div>
  </>;

  const panes = { general, tools, workAtOnce, sessions, policy, agentConfiguration };
  return (
    <Modal label={projectSettingsWords.title} close={close}>
      <div class="sheet-body settings-sheet">
        <h2>{projectSettingsWords.title}: {project.value?.name ?? summary.name}</h2>
        <div class="tabs" role="tablist" aria-label={projectSettingsWords.title}>
          {projectPanes.map((p) => <button type="button" key={p.id} role="tab" aria-selected={pane.value === p.id}
            class={pane.value === p.id ? "on" : ""} onClick={() => (pane.value = p.id)}>{p.title}</button>)}
        </div>
        <div role="tabpanel">
          {pane.value !== "tools" && pane.value !== "policy" && note}
          {panes[pane.value]}
        </div>
        {problem.value && <p class="sheet-note failure" role="alert">{problem.value}</p>}
        <div class="sheet-actions"><button type="button" class="prominent" onClick={close}>Done</button></div>
      </div>
      {config.value && <ProjectAgentConfigModal store={store} host={host} folder={folder} down={down}
        close={() => { config.value = false; }} />}
    </Modal>
  );
}

export function FolderSettingsModal({ store, host, folder, summary, down, close, openProject }: Props & {
  /** The project's settings, in place of this dialog. */
  openProject: () => void;
}) {
  const pane = useSignal<FolderPane>("general");
  const choosing = useSignal(false);
  // The project's name, from projects/list; the folder's own name until it is read.
  const projectName = useSignal<string | undefined>(undefined);
  useEffect(() => {
    if (summary.project === undefined) { projectName.value = undefined; return; }
    void store.link.call("projects/list", {})
      .then((list) => { projectName.value = list.projects.find((p) => p.id === summary.project)?.name; })
      .catch(() => { projectName.value = undefined; });
  }, [summary.project, choosing.value]);
  const { problem, busy, save } = useSaving();
  const off = down || busy.value;
  const disk = summary.folder.diskSpace;
  const low = disk?.lowGB ?? diskDefaults.lowGB;
  const critical = disk?.criticalGB ?? diskDefaults.criticalGB;
  const line = (key: "lowGB" | "criticalGB", current: number, standard: number, choices: readonly number[], label: string) => (
    <select aria-label={label} disabled={off} value={String(current)}
      onChange={(e) => void save(() => store.setFolderDiskSpace(host, folder,
        withDiskLine(disk, key, Number((e.currentTarget as HTMLSelectElement).value), standard)))}>
      {diskChoices(choices, current).map((n) => <option key={n} value={String(n)}>{n === standard ? `${n} GB (default)` : `${n} GB`}</option>)}
    </select>
  );
  const general = <dl class="settings-grid">
    <dt>Folder</dt>
    <dd>{folderPathOf(folder)}{!summary.exists && <p class="sheet-note failure">Folder is missing</p>}</dd>
    <dt>Machine</dt><dd>{machineName(store, host)}</dd>
    <dt>Project</dt>
    <dd>
      {summary.project !== undefined && <span>{projectName.value ?? summary.name}</span>}
      <button type="button" disabled={down} onClick={() => (choosing.value = true)}>Choose Project…</button>
      {summary.projectProblem && <p class="sheet-note failure">{summary.projectProblem}</p>}
    </dd>
  </dl>;
  const diskSpace = <dl class="settings-grid">
    <dt>Low disk space</dt><dd>{line("lowGB", low, diskDefaults.lowGB, diskDefaults.lowChoices, "Low disk space")}</dd>
    <dt>Critical disk space</dt>
    <dd>
      {line("criticalGB", critical, diskDefaults.criticalGB, diskDefaults.criticalChoices, "Critical disk space")}
      <p class="sheet-note">When free space on the disk holding this folder or its worktrees falls below these, the page
        says so and machine.disk_low is raised for agents and workflows. Low is also below {disk?.lowPercent ?? diskDefaults.lowPercent}%
        of the disk. Saved in .agents/folder.json.</p>
    </dd>
  </dl>;
  return (
    <Modal label={projectSettingsWords.folderTitle} close={close}>
      <div class="sheet-body settings-sheet">
        <h2>{projectSettingsWords.folderTitle}: {summary.name}</h2>
        <div class="tabs" role="tablist" aria-label={projectSettingsWords.folderTitle}>
          {folderPanes.map((p) => <button type="button" key={p.id} role="tab" aria-selected={pane.value === p.id}
            class={pane.value === p.id ? "on" : ""} onClick={() => (pane.value = p.id)}>{p.title}</button>)}
        </div>
        <div role="tabpanel">{pane.value === "general" ? general : diskSpace}</div>
        {problem.value && <p class="sheet-note failure" role="alert">{problem.value}</p>}
        <div class="sheet-actions">
          <button type="button" onClick={openProject}>{projectSettingsWords.menuItem}</button>
          <button type="button" class="prominent" onClick={close}>Done</button>
        </div>
      </div>
      {choosing.value && <ProjectModal store={store} host={host} folder={folder} summary={summary}
        close={() => { choosing.value = false; }} />}
    </Modal>
  );
}

function Switch({ label, on, set, disabled }: { label: string; on: boolean; set: (on: boolean) => void; disabled: boolean }) {
  return (
    <label class="switch-row">
      <input type="checkbox" role="switch" checked={on} disabled={disabled}
        onChange={(e) => set((e.currentTarget as HTMLInputElement).checked)} />
      {label}
    </label>
  );
}
