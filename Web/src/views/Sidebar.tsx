// The page's one sidebar from 760 wide (#151), as the window's (#145, ProjectListView.swift):
// Activity at the top, then every project, each a row that folds open on its sessions and
// workflows, and at the foot what the hosts and this browser are doing. No host headings: a
// server's project reads `host:Project`. A project's row opens its Dashboard.
//
// One list for the keys: ↑ and ↓ move through every row shown, opening what they land on, as the
// window's selection does; → unfolds a project and ← folds it, or steps out to its project from
// a row under it. The menu key, Shift-F10 or a right click opens a row's menu.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import { actDoing, type Store } from "../model/store";
import { agentsIn, folderKey, headings, projectSubtitle, showsUnread } from "../model/groups";
import { folds } from "../model/folds";
import { parseQuery, queryMatches } from "../model/labels";
import { workflowSummary } from "../model/workflows";
import type { Agent, ControlHost, ProjectSummary } from "../protocol/generated";
import { go, route, type ActivityPage } from "../route";
import { browserName, type Session } from "../session";
import { ActivityRows } from "./Activity";
import { isMenuKey, openContextMenu, type MenuItem } from "./ContextMenu";
import { CloningRows, EmptyProjects, NewProjectMenu } from "./NewProject";
import { SessionRow } from "./SessionRow";
import { blockLines } from "../model/block";
import { sessionActions } from "./SessionMenu";
import { WorkflowRow } from "./WorkflowRow";
import { PinnedPageRows } from "./Pins";

/** Enough archived sessions to find last week's, as the window shows. */
const archivedShown = 50;

/** A project's name in the sidebar: `host:Project` on a server, the name alone on this Mac. */
export function projectLabel(host: ControlHost | undefined, project: ProjectSummary): string {
  return !host || host.id === "mac" ? project.name : `${host.name}:${project.name}`;
}

/** This Mac's projects, then each server's, each by name: no heading for a host. */
function orderedProjects(store: Store): { host: ControlHost; project: ProjectSummary }[] {
  const hosts = store.hosts.value;
  const ordered = [...hosts.filter((h) => h.id === "mac"), ...hosts.filter((h) => h.id !== "mac")];
  return ordered.flatMap((host) => [...(store.projects.value[host.id] ?? [])]
    .sort((a, b) => a.name.localeCompare(b.name))
    .map((project) => ({ host, project })));
}

export function Sidebar({ session, store, linkDown }: { session: Session; store: Store; linkDown: boolean }) {
  const search = useSignal("");
  const confirming = useSignal(false);
  const r = route.value;
  // What is open, from anywhere (a link, Back), unfolds its project so its row is there to light.
  useEffect(() => {
    if (r.host && r.project && (r.session || r.workflow || r.page)) folds.set(r.host, r.project, true);
  }, [r.host, r.project, r.session, r.workflow, r.page]);
  const projects = orderedProjects(store);
  const offline = store.hosts.value.filter((h) => h.state !== "online");
  return (
    <nav class="sidebar" aria-label="Sidebar">
      <header class="column-head sidebar-head">
        <input class="search" type="search" placeholder="Search sessions and workflows"
          aria-label="Search sessions and workflows" value={search.value}
          onInput={(e) => (search.value = (e.currentTarget as HTMLInputElement).value)} />
        {/* New project where the window's + sits over its sidebar (#115). */}
        <NewProjectMenu store={store} />
      </header>
      <div class="scroll" onKeyDown={(e) => moveWithKeys(e)}>
        {!search.value.trim() && (
          <section class="activity" aria-label="Activity">
            <h2 class="sidebar-head-label">Activity</h2>
            <ActivityRows store={store} chosen={r.activity} onPick={(page: ActivityPage) => go({ activity: page })} />
          </section>
        )}
        <section class="project-list" aria-label="Projects">
          <h2 class="sidebar-head-label">Projects</h2>
          {projects.map(({ host, project }) => (
            <ProjectFold key={`${host.id}|${project.project.folder}`} store={store} host={host} project={project}
              query={search.value} linkDown={linkDown} />
          ))}
          {store.hosts.value.map((host) => <CloningRows key={host.id} store={store} host={host.id} />)}
          <EmptyProjects store={store} />
        </section>
      </div>
      {/* What the hosts and this browser are doing, pinned at the foot: status lines rather than
          somewhere to go. Each is absent when there is nothing to say. */}
      <footer class="sidebar-foot">
        {offline.map((host) => host.id === "mac" ? (
          <div class="host-down" role="status" key={host.id}>
            <p class="strong">⚠︎ This Mac’s host isn’t answering</p>
            <p class="quiet small">What’s listed is what it last said. The control plane is trying again by itself.</p>
          </div>
        ) : (
          <p class="foot-line" role="status" key={host.id}>
            <span aria-hidden="true">⚡︎</span> {host.name} is {host.state === "connecting" ? "connecting…" : "offline"}
          </p>
        ))}
        <div class="identity">
          <span>{browserName()} on this Mac</span>
          {confirming.value ? (
            <span class="confirm">
              <button onClick={() => void session.forgetThisBrowser()}>Forget</button>
              <button onClick={() => (confirming.value = false)}>Cancel</button>
            </span>
          ) : (
            <button class="link" onClick={() => (confirming.value = true)}>Forget This Browser…</button>
          )}
        </div>
      </footer>
    </nav>
  );
}

/**
 * One project: its row, and folded under it its sessions, Needs you first, then its workflows,
 * each kind's archived ones folded once more at its foot. A search unfolds every project with
 * something that matches and hides the rest.
 */
function ProjectFold({ store, host, project, query, linkDown }: {
  store: Store; host: ControlHost; project: ProjectSummary; query: string; linkDown: boolean;
}) {
  const r = route.value;
  const folder = project.project.folder;
  const label = projectLabel(host, project);
  const searching = query.trim() !== "";
  const unfolded = searching || folds.isOpen(host.id, folder);
  const down = linkDown || !store.hostIsOnline(host.id);
  const showsArchived = searching || folds.isOpen(host.id, folder, "archivedSessions");
  useEffect(() => {
    if (unfolded && store.hostIsOnline(host.id)) void store.loadWorkflows(host.id, folder);
  }, [unfolded, host.id, folder]);
  useEffect(() => {
    if (showsArchived && store.hostIsOnline(host.id)) void store.loadArchived(host.id, folder);
  }, [showsArchived, host.id, folder]);

  const agents: Agent[] = store.agents.value[host.id] ?? [];
  const parsed = parseQuery(query);
  const matching = (list: Agent[]) => (searching ? list.filter((a) => queryMatches(parsed, a)) : list);
  const groups = headings(agents, folder).map((h) => ({ ...h, agents: matching(h.agents) })).filter((h) => h.agents.length > 0);
  const archived = matching(agentsIn(agents, folder, "archived"));
  const runtimeName = (id: string) => (store.runtimes.value[host.id] ?? []).find((s) => s.runtime.id === id)?.runtime.name;
  // A search narrows workflows by name and what they are; one asking for a label leaves them out.
  const allWorkflows = (store.workflows.value[`${host.id}|${folderKey(folder)}`] ?? [])
    .filter((w) => !searching || parsed.label === null && (!parsed.text
      || [w.workflow.name, workflowSummary(w.workflow, runtimeName)].some((t) => t.toLowerCase().includes(parsed.text.toLowerCase()))))
    .sort((a, b) => a.workflow.name.localeCompare(b.workflow.name));
  const workflows = allWorkflows.filter((w) => !w.isArchived);
  const archivedWorkflows = allWorkflows.filter((w) => w.isArchived);
  const nameMatches = label.toLowerCase().includes(query.trim().toLowerCase());
  if (searching && groups.length === 0 && archived.length === 0 && allWorkflows.length === 0 && !nameMatches) return null;

  const chosen = r.host === host.id && r.project !== undefined && folderKey(r.project) === folderKey(folder)
    && !!r.dashboard;
  const needs = agentsIn(agents, folder, "needsAttention").length > 0;
  const subtitle = !project.exists ? "Folder is missing" : projectSubtitle(agents, folder);
  const fold = (open: boolean) => folds.set(host.id, folder, open);
  const pick = (agent: Agent) => go({ host: host.id, project: folder, session: agent.id });
  const going = (agent: Agent) => {
    const act = store.onItsWay.value[agent.id];
    return act && typeof act === "string" ? { doing: actDoing(act), recipient: store.recipient(host.id) } : undefined;
  };
  const projectMenu: MenuItem[] = [
    { label: "Dashboard", run: () => go({ host: host.id, project: folder, dashboard: true }) },
    { label: "New Session", disabled: down, help: "Start a new session in this project",
      run: () => go({ host: host.id, project: folder, compose: true }) },
  ];
  const sessionMenu = (agent: Agent): MenuItem[] => sessionActions(agent).map(({ action, label: words, help }) => ({
    label: words, help, disabled: down || !!store.onItsWay.value[agent.id],
    run: () => {
      if (action === "markRead" || action === "markUnread") void store.setUnread(host.id, agent.id, action === "markUnread");
      else void store.perform(host.id, agent.id, action);
    },
  }));
  const row = (agent: Agent) => (
    <div class="nav-item" key={agent.id} onContextMenu={(e) => openContextMenu(e, sessionMenu(agent))}
      onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, sessionMenu(agent)); }}>
      <SessionRow agent={agent} chosen={r.session === agent.id} onPick={() => pick(agent)} going={going(agent)}
        waits={blockLines(agent, store.agents.value[host.id] ?? [])} />
    </div>
  );
  return (
    <div class={`project-fold${down && !linkDown ? " greyed" : ""}`} role="group" aria-label={label}
      data-host={host.id} data-folder={folder}>
      <div class={`row project${chosen ? " chosen" : ""}`}>
        <button class="disclosure" aria-label={unfolded ? `Fold ${label}` : `Unfold ${label}`} aria-expanded={unfolded}
          tabIndex={-1} disabled={searching} onClick={() => fold(!unfolded)}>{unfolded ? "⌄" : "›"}</button>
        <button class="pick" aria-current={chosen} aria-expanded={unfolded} data-fold="project" title={folderPath(folder)}
          onClick={() => go({ host: host.id, project: folder, dashboard: true })}
          onContextMenu={(e) => openContextMenu(e, projectMenu)}
          onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, projectMenu); }}>
          <span class="title">{label}</span>
          {/* Folded, the row says what is under it; unfolded, the rows under it say that. */}
          {(!unfolded || !project.exists) && subtitle && <span class="subtitle">{subtitle}</span>}
        </button>
        {needs && <span class="dot" aria-label="Needs you" />}
      </div>
      {unfolded && (
        <div class="fold-body">
          {/* The project's pinned pages (#159), beside the Dashboard its row opens, before its sessions. */}
          {!searching && (
            <PinnedPageRows store={store} host={host.id} folder={folder} down={down}
              chosen={r.host === host.id && r.project !== undefined && folderKey(r.project) === folderKey(folder) ? r.page : undefined} />
          )}
          {groups.map((group) => (
            <div class="group" key={group.group} role="group" aria-label={group.title}>
              <h3 class={`subhead${group.group === "needsAttention" ? " needs" : ""}`}>
                {group.title} <span class="count">{group.agents.length}</span>
                {group.agents.some(showsUnread) && <span class="count"> · {group.agents.filter(showsUnread).length} unread</span>}
              </h3>
              {group.agents.map(row)}
            </div>
          ))}
          {!searching && groups.length === 0 && <p class="hint">No sessions yet</p>}
          {(archived.length > 0 || (project.counts.archived ?? 0) > 0 || project.retiredCount > 0) && (
            <details class="archived" open={showsArchived}
              onToggle={(e) => {
                const open = (e.currentTarget as HTMLDetailsElement).open;
                if (!searching && open !== showsArchived) folds.set(host.id, folder, open, "archivedSessions");
              }}>
              <summary class="subhead" data-fold="archivedSessions">Archived sessions{" "}
                <span class="count">{showsArchived ? archived.length : Math.max(archived.length, project.counts.archived ?? 0)}</span>
              </summary>
              {(searching ? archived : archived.slice(0, archivedShown)).map(row)}
              {showsArchived && project.retiredCount > 0 && !searching && (
                <p class="hint">{project.retiredCount === 1 ? "1 older agent has been retired."
                  : `${project.retiredCount} older agents have been retired.`}</p>
              )}
            </details>
          )}
          {(workflows.length > 0 || archivedWorkflows.length > 0) && (
            <div class="group" role="group" aria-label="Workflows">
              <h3 class="subhead">Workflows <span class="count">{workflows.length}</span></h3>
              {workflows.map((summary) => (
                <div class="nav-item" key={summary.workflow.workflowID}>
                  <WorkflowRow store={store} host={host.id} summary={summary} disabled={down}
                    chosen={r.workflow === summary.workflow.workflowID}
                    onPick={() => go({ host: host.id, project: folder, workflow: summary.workflow.workflowID })} />
                </div>
              ))}
              {archivedWorkflows.length > 0 && (
                <details class="archived" open={searching || folds.isOpen(host.id, folder, "archivedWorkflows")}
                  onToggle={(e) => {
                    if (!searching) folds.set(host.id, folder, (e.currentTarget as HTMLDetailsElement).open, "archivedWorkflows");
                  }}>
                  <summary class="subhead" data-fold="archivedWorkflows">Archived workflows <span class="count">{archivedWorkflows.length}</span></summary>
                  {archivedWorkflows.map((summary) => (
                    <div class="nav-item" key={summary.workflow.workflowID}>
                      <WorkflowRow store={store} host={host.id} summary={summary} disabled={down}
                        chosen={r.workflow === summary.workflow.workflowID}
                        onPick={() => go({ host: host.id, project: folder, workflow: summary.workflow.workflowID })} />
                    </div>
                  ))}
                </details>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

/** The folder as a person reads it, for the row's tooltip. */
function folderPath(folder: string): string {
  try {
    return decodeURIComponent(new URL(folder).pathname).replace(/\/$/, "");
  } catch {
    return folder;
  }
}

/** Every row the keys move through, in the order shown. */
function navRows(list: HTMLElement): HTMLElement[] {
  return [...list.querySelectorAll<HTMLElement>(
    ".activity .row, .project-fold > .row.project .pick, .nav-item .row.pin .pick, .nav-item .row.session, .nav-item .row.workflow .pick, details.archived > summary",
  )].filter((el) => el.offsetParent !== null);
}

/**
 * ↑ and ↓ through the list, opening what they land on (a fold's summary is landed on and not
 * opened); → unfolds and ← folds, or steps out to the project; Home and End.
 */
function moveWithKeys(e: KeyboardEvent): void {
  const list = e.currentTarget as HTMLElement;
  const rows = navRows(list);
  const here = rows.findIndex((el) => el === document.activeElement || el.contains(document.activeElement));
  if (here < 0 || e.altKey || e.metaKey || e.ctrlKey) return;
  const current = rows[here]!;
  const land = (el: HTMLElement | undefined) => {
    if (!el) return;
    e.preventDefault();
    el.focus();
    el.scrollIntoView({ block: "nearest" });
    if (el.tagName !== "SUMMARY") el.click();
  };
  const fold = current.closest<HTMLElement>(".project-fold");
  const isProject = current.matches(".pick[data-fold=project]");
  switch (e.key) {
    case "ArrowDown": land(rows[here + 1]); break;
    case "ArrowUp": land(rows[here - 1]); break;
    case "Home": land(rows[0]); break;
    case "End": land(rows[rows.length - 1]); break;
    case "ArrowRight":
      if (isProject && fold && current.getAttribute("aria-expanded") !== "true") {
        e.preventDefault();
        folds.set(fold.dataset.host!, fold.dataset.folder!, true);
      } else if (current.tagName === "SUMMARY" && !(current.parentElement as HTMLDetailsElement).open) {
        e.preventDefault();
        current.click();
      }
      break;
    case "ArrowLeft":
      if (isProject && fold && current.getAttribute("aria-expanded") === "true") {
        e.preventDefault();
        folds.set(fold.dataset.host!, fold.dataset.folder!, false);
      } else if (current.tagName === "SUMMARY" && (current.parentElement as HTMLDetailsElement).open) {
        e.preventDefault();
        current.click();
      } else if (fold && !isProject) {
        e.preventDefault();
        fold.querySelector<HTMLElement>(".pick[data-fold=project]")?.focus();
      }
      break;
  }
}
