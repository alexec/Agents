// The page's one sidebar (#151), as the window's (#145, ProjectListView.swift), and below 760 the
// root list, as the iPhone Remote's (#226, #235):
// Activity at the top, then every project, each a row that folds open on its sessions and
// workflows, and at the foot what the hosts and this browser are doing. No host headings: a
// server's project reads `host:Project`. A project's row starts a new session in it and folds (#366).
//
// One list for the keys: ↑ and ↓ move through every row shown, opening what they land on, as the
// window's selection does; → unfolds a project and ← folds it, or steps out to its project from
// a row under it. The menu key, Shift-F10 or a right click opens a row's menu.
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import { actDoing, type Store } from "../model/store";
import { folderKey, groupOf, showsUnread } from "../model/groups";
import { folds } from "../model/folds";
import { parseQuery, queryMatches } from "../model/labels";
import { namedRelative, workflowSummary } from "../model/workflows";
import { fromWireDate } from "../protocol/dates";
import type { Agent, ControlHost, ProjectSummary } from "../protocol/generated";
import { go, route, type ActivityPage } from "../route";
import { browserName, type Session } from "../session";
import { ActivityRows } from "./Activity";
import { isMenuKey, openContextMenu, type MenuItem } from "./ContextMenu";
import { CloningRows, EmptyProjects, NewProjectMenu } from "./NewProject";
import { rowExtras, SessionRow } from "./SessionRow";
import { runSessionAction, sessionActions } from "./SessionMenu";
import { WorkflowRow } from "./WorkflowRow";
import { PinnedPageRows } from "./Pins";
import { memo } from "../render/memo";

/** Enough archived sessions to find last week's, as the window shows. */
const archivedShown = 50;

/** The most archived matches a fold shows before Show all, as the window's (#176). */
const matchesShown = 10;

/** How long the typing pauses before the folds filter and the hosts are asked (#176). */
export const searchPause = 150;

/** A project's name in the sidebar: `host:Project` on a server, the name alone on this Mac. */
export function projectLabel(host: ControlHost | undefined, project: ProjectSummary): string {
  return !host || host.id === "mac" ? project.name : `${host.name}:${project.name}`;
}

/**
 * Oldest added first, then by folder, as the window's and the Remote's (SidebarOrder.byAdded,
 * #357): a row stays where it is however busy its project is, and a new project lands at the end.
 */
export function byAdded(a: ProjectSummary, b: ProjectSummary): number {
  if (a.project.addedAt !== b.project.addedAt) return a.project.addedAt - b.project.addedAt;
  const [x, y] = [folderKey(a.project.folder), folderKey(b.project.folder)];
  return x < y ? -1 : x > y ? 1 : 0;
}

/**
 * This Mac's projects, then each server's, each oldest added first, as the window's and the
 * Remote's (SidebarOrder.projects, #250, #357): no heading for a host.
 */
export function orderedProjects(hosts: ControlHost[], projects: Record<string, ProjectSummary[]>):
  { host: ControlHost; project: ProjectSummary }[] {
  const ordered = [...hosts.filter((h) => h.id === "mac"), ...hosts.filter((h) => h.id !== "mac")];
  return ordered.flatMap((host) => (projects[host.id] ?? [])
    .filter((project) => project.project.archivedAt === undefined)
    .sort(byAdded)
    .map((project) => ({ host, project })));
}

/** Every host's archived projects, the latest worked on first, as the window's Archived projects (#343). */
export function archivedProjects(hosts: ControlHost[], projects: Record<string, ProjectSummary[]>):
  { host: ControlHost; project: ProjectSummary }[] {
  return hosts.flatMap((host) => (projects[host.id] ?? [])
    .filter((project) => project.project.archivedAt !== undefined)
    .map((project) => ({ host, project })))
    .sort((a, b) => b.project.lastActivityAt - a.project.lastActivityAt);
}

export function Sidebar({ session, store, linkDown }: { session: Session; store: Store; linkDown: boolean }) {
  const search = useSignal("");
  // What the folds filter by: the field's words once typing pauses, so a keystroke costs the
  // field and not a pass over every project (#176, #193).
  const searched = useSignal("");
  const confirming = useSignal(false);
  const r = route.value;
  // After a pause in the typing: the folds filter what is held, and the archived sessions that
  // match are the hosts' to find, a capped page each (#165).
  useEffect(() => {
    const words = search.value.trim();
    if (words === searched.value) return;
    const timer = setTimeout(() => {
      searched.value = words;
      void store.searchSessions(words);
    }, words ? searchPause : 0);
    return () => clearTimeout(timer);
  }, [search.value]);
  // What is open, from anywhere (a link, Back), unfolds its project so its row is there to light.
  useEffect(() => {
    if (r.host && r.project && (r.session || r.workflow || r.page)) folds.set(r.host, r.project, true);
  }, [r.host, r.project, r.session, r.workflow, r.page]);
  const projects = orderedProjects(store.hosts.value, store.projects.value);
  const archived = archivedProjects(store.hosts.value, store.projects.value);
  const showsArchived = folds.showsArchivedProjects.value;
  const offline = store.hosts.value.filter((h) => h.state !== "online");
  return (
    <nav class="sidebar" aria-label="Sidebar">
      <header class="column-head sidebar-head">
        {/* The root list's title at a phone's width, as the iPhone's (#235). */}
        <h1 class="narrow-only">Agents</h1>
        <input class="search" type="search" placeholder="Search sessions and workflows"
          aria-label="Search sessions and workflows" value={search.value}
          onInput={(e) => (search.value = (e.currentTarget as HTMLInputElement).value)} />
        {/* New project where the window's + sits over its sidebar (#115). */}
        <NewProjectMenu store={store} />
      </header>
      <div class="scroll" onKeyDown={(e) => moveWithKeys(e)}>
        {!searched.value && (
          <section class="activity" aria-label="Activity">
            <h2 class="sidebar-head-label">Activity</h2>
            <ActivityRows store={store} chosen={r.activity} onPick={(page: ActivityPage) => go({ activity: page })} />
          </section>
        )}
        <section class="project-list" aria-label="Projects">
          <h2 class="sidebar-head-label">Projects</h2>
          {projects.map(({ host, project }) => (
            <ProjectFold key={`${host.id}|${project.project.folder}`} store={store} host={host} project={project}
              query={searched.value} linkDown={linkDown} />
          ))}
          {/* A host had more matches than its page: the next page, on asking (#176). */}
          {searched.value && Object.keys(store.searchNext.value).length > 0 && (
            <button class="link more-matches" onClick={() => void store.searchMore()}>More matches…</button>
          )}
          {store.hosts.value.map((host) => <CloningRows key={host.id} store={store} host={host.id} />)}
          <EmptyProjects store={store} />
        </section>
        {/* Projects put away, under their own heading, closed until opened, as the window's (#343). */}
        {!searched.value && archived.length > 0 && (
          <details class="archived archived-projects" open={showsArchived}
            onToggle={(e) => folds.setShowsArchivedProjects((e.currentTarget as HTMLDetailsElement).open)}>
            <summary class="sidebar-head-label" data-fold="archivedProjects">Archived projects</summary>
            {showsArchived && archived.map(({ host, project }) => (
              <ArchivedProjectRow key={`${host.id}|${project.project.folder}`} store={store} host={host} project={project}
                down={linkDown || !store.hostIsOnline(host.id)} />
            ))}
          </details>
        )}
      </div>
      {/* What the hosts and this browser are doing, pinned at the foot: status lines rather than
          somewhere to go. Each is absent when there is nothing to say. */}
      <footer class="sidebar-foot">
        {/* This Mac's host still connecting is said as the window says it, not as down (#250). */}
        {offline.map((host) => host.id === "mac" && host.state === "connecting" ? (
          <p class="foot-line quiet" role="status" key={host.id}>Connecting…</p>
        ) : host.id === "mac" ? (
          <div class="host-down" role="status" key={host.id}>
            <p class="strong">⚠︎ This Mac’s host isn’t answering</p>
            <p class="quiet small">What’s listed is what it last said. The control plane is trying again by itself.</p>
          </div>
        ) : (
          <p class="foot-line" role="status" key={host.id}>
            <span aria-hidden="true">⚡︎</span> {host.name} is {host.state === "connecting" ? "connecting…" : "offline"}
          </p>
        ))}
        {/* A file a host keeps that could not be read (#205, #223): why paired devices or projects
            may have gone from view, and that what they held is kept. A server's are named. */}
        {store.hosts.value.flatMap((host) => (store.storeNotes.value[host.id] ?? []).map((note) => (
          <p class="foot-line store-note" role="status" key={`${host.id}|${note}`}>
            <span aria-hidden="true">⚠︎</span> {host.id === "mac" ? note : `${host.name}: ${note}`}
          </p>
        )))}
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
 * something that matches and hides the rest. It reads its own project's agents alone, so a change
 * to an agent draws one fold again, and a folded one reads nothing of its sessions (#170). `query`
 * is the search's words, already trimmed.
 */
const ProjectFold = memo(function ProjectFold({ store, host, project, query, linkDown }: {
  store: Store; host: ControlHost; project: ProjectSummary; query: string; linkDown: boolean;
}) {
  const r = route.value;
  const folder = project.project.folder;
  const label = projectLabel(host, project);
  const searching = query !== "";
  const unfolded = searching || folds.isOpen(host.id, folder);
  const down = linkDown || !store.hostIsOnline(host.id);
  // A search's archived matches come from the hosts (#193), not from a page of every fold.
  const archivedFoldOpen = folds.isOpen(host.id, folder, "archivedSessions");
  const showsArchived = searching || archivedFoldOpen;
  // Every match on show, past the first few; a new search shows the few again.
  const showsAllMatches = useSignal(false);
  useEffect(() => { showsAllMatches.value = false; }, [query]);
  const showsWorkflows = searching || folds.isOpen(host.id, folder, "workflows");
  const online = store.hostIsOnline(host.id);
  // The list is held while the project is open, and let go when it folds (#291).
  useEffect(() => {
    if (!unfolded || !online) return;
    store.holdWorkflows(host.id, folder);
    return () => store.releaseWorkflows(host.id, folder);
  }, [unfolded, online, host.id, folder]);
  // Archived sessions are held while their fold is open, a page of them, and let go when it closes.
  const archivedWasShown = useRef(false);
  useEffect(() => {
    if (archivedFoldOpen && store.hostIsOnline(host.id)) void store.loadArchived(host.id, folder);
    if (!archivedFoldOpen && archivedWasShown.current) store.unloadArchived(host.id, folder);
    archivedWasShown.current = archivedFoldOpen;
  }, [archivedFoldOpen, host.id, folder]);

  const view = store.projectView(host.id, folder);
  // The matcher is made once per fold, not per row.
  const parsed = parseQuery(query);
  const matching = (list: Agent[]) => (searching ? list.filter((a) => queryMatches(parsed, a)) : list);
  // The pinned sessions (#180), held and not archived, in their order; they leave their groups.
  const pinnedIDs = store.sessionPinsIn(host.id, folder);
  const live = view.headings.flatMap((h) => h.agents);
  const pinned = !unfolded ? [] : matching(pinnedIDs.flatMap((id) => live.filter((a) => a.id === id)));
  const showsPinned = searching || folds.isOpen(host.id, folder, "pinned");
  const groups = !unfolded ? [] : view.headings
    .map((h) => ({ ...h, agents: matching(pinnedIDs.length ? h.agents.filter((a) => !pinnedIDs.includes(a.id)) : h.agents) }))
    .filter((h) => h.agents.length > 0);
  const archived = !unfolded ? [] : matching(view.archived);
  const runtimeName = (id: string) => (store.runtimes.value[host.id] ?? []).find((s) => s.runtime.id === id)?.runtime.name;
  // A search narrows workflows by name and what they are; one asking for a label leaves them out.
  const allWorkflows = (unfolded ? store.projectWorkflows(host.id, folder) : [])
    .filter((w) => !searching || parsed.label === null && (!parsed.text
      || [w.workflow.name, workflowSummary(w.workflow, runtimeName)].some((t) => t.toLowerCase().includes(parsed.text.toLowerCase()))))
    .sort((a, b) => a.workflow.name.localeCompare(b.workflow.name));
  const workflows = allWorkflows.filter((w) => !w.isArchived);
  const archivedWorkflows = allWorkflows.filter((w) => w.isArchived);
  const nameMatches = label.toLowerCase().includes(query.toLowerCase());
  if (searching && groups.length === 0 && archived.length === 0 && allWorkflows.length === 0 && !nameMatches) return null;

  const chosen = r.host === host.id && r.project !== undefined && folderKey(r.project) === folderKey(folder)
    && !!r.compose;
  const needs = view.needsYou;
  const subtitle = !project.exists ? "Folder is missing" : view.subtitle;
  const fold = (open: boolean) => folds.set(host.id, folder, open);
  const projectMenu: MenuItem[] = [
    { label: "New Session", disabled: down, help: "Start a new session in this project",
      run: () => go({ host: host.id, project: folder, compose: true }) },
  ];
  const row = (agent: Agent) => (
    <SidebarSession key={agent.id} store={store} host={host.id} folder={folder} agent={agent}
      chosen={r.session === agent.id} down={down} />
  );
  return (
    <div class={`project-fold${down && !linkDown ? " greyed" : ""}`} role="group" aria-label={label}
      data-host={host.id} data-folder={folder}>
      <div class={`row project${chosen ? " chosen" : ""}`}>
        <button class="disclosure" aria-label={unfolded ? `Fold ${label}` : `Unfold ${label}`} aria-expanded={unfolded}
          tabIndex={-1} disabled={searching} onClick={() => fold(!unfolded)}>{unfolded ? "⌄" : "›"}</button>
        <button class="pick" aria-current={chosen} aria-expanded={unfolded} data-fold="project" title={folderPath(folder)}
          onClick={(e) => {
            // A new session in it, and the row folds or unfolds (#366). Not when the arrow keys
            // land here (a click with no detail): moving through the list folds nothing.
            go({ host: host.id, project: folder, compose: true });
            if (e.detail > 0 && !searching) fold(!unfolded);
          }}
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
          {/* The project's pinned pages (#159), before its sessions. */}
          {!searching && (
            <PinnedPageRows store={store} host={host.id} folder={folder} down={down}
              chosen={r.host === host.id && r.project !== undefined && folderKey(r.project) === folderKey(folder) ? r.page : undefined} />
          )}
          {/* Then the pinned sessions (#180), whatever their state, moved by their menus' Move Up and Down. */}
          {pinned.length > 0 && (
            <details class="group pinned" role="group" aria-label="Pinned" open={showsPinned}
              onToggle={(e) => {
                const now = (e.currentTarget as HTMLDetailsElement).open;
                if (!searching && now !== showsPinned) folds.set(host.id, folder, now, "pinned");
              }}>
              <summary class={`subhead${pinned.some((a) => groupOf(a) === "needsAttention") ? " needs" : ""}`} data-fold="pinned">
                Pinned <span class="count">{pinned.length}</span>
                {pinned.some(showsUnread) && <span class="count"> · {pinned.filter(showsUnread).length} unread</span>}
              </summary>
              {showsPinned && pinned.map((agent) => (
                <SidebarSession key={agent.id} store={store} host={host.id} folder={folder} agent={agent}
                  chosen={r.session === agent.id} down={down} pinnedAt={searching ? undefined : pinnedIDs} />
              ))}
            </details>
          )}
          {/* Each group folds at its heading, as the window's do (#181); a search shows every match. */}
          {groups.map((group) => {
            const fold = `group.${group.group}` as const;
            const open = searching || folds.isOpen(host.id, folder, fold);
            return (
              <details class="group" key={group.group} role="group" aria-label={group.title} open={open}
                onToggle={(e) => {
                  const now = (e.currentTarget as HTMLDetailsElement).open;
                  if (!searching && now !== open) folds.set(host.id, folder, now, fold);
                }}>
                <summary class={`subhead${group.group === "needsAttention" ? " needs" : ""}`} data-fold={fold}>
                  {group.title} <span class="count">{group.agents.length}</span>
                  {group.agents.some(showsUnread) && <span class="count"> · {group.agents.filter(showsUnread).length} unread</span>}
                </summary>
                {open && group.agents.map(row)}
              </details>
            );
          })}
          {/* Only with no live session at all, pinned ones counted, as the window's (#250). */}
          {!searching && live.length === 0 && <p class="hint">No sessions yet</p>}
          {(archived.length > 0 || (project.counts.archived ?? 0) > 0 || project.retiredCount > 0) && (
            <details class="archived" open={showsArchived}
              onToggle={(e) => {
                const open = (e.currentTarget as HTMLDetailsElement).open;
                if (!searching && open !== showsArchived) folds.set(host.id, folder, open, "archivedSessions");
              }}>
              <summary class="subhead" data-fold="archivedSessions">Archived sessions{" "}
                <span class="count">{showsArchived ? archived.length : Math.max(archived.length, project.counts.archived ?? 0)}</span>
              </summary>
              {archived.slice(0, !searching ? archivedShown : showsAllMatches.value ? archived.length : matchesShown).map(row)}
              {searching && !showsAllMatches.value && archived.length > matchesShown && (
                <button class="link show-all" onClick={() => (showsAllMatches.value = true)}>Show all {archived.length}</button>
              )}
              {showsArchived && project.retiredCount > 0 && !searching && (
                <p class="hint">{project.retiredCount === 1 ? "1 older agent has been retired."
                  : `${project.retiredCount} older agents have been retired.`}</p>
              )}
            </details>
          )}
          {(workflows.length > 0 || archivedWorkflows.length > 0) && (
            <details class="group" role="group" aria-label="Workflows" open={showsWorkflows}
              onToggle={(e) => {
                const now = (e.currentTarget as HTMLDetailsElement).open;
                if (!searching && now !== showsWorkflows) folds.set(host.id, folder, now, "workflows");
              }}>
              <summary class="subhead" data-fold="workflows">Workflows <span class="count">{workflows.length}</span></summary>
              {showsWorkflows && workflows.map((summary) => (
                <div class="nav-item" key={summary.workflow.workflowID}>
                  <WorkflowRow store={store} host={host.id} summary={summary} disabled={down}
                    chosen={r.workflow === summary.workflow.workflowID}
                    onPick={() => go({ host: host.id, project: folder, workflow: summary.workflow.workflowID })} />
                </div>
              ))}
            </details>
          )}
          {/* A sibling of Workflows, not inside it, so folding Workflows leaves it, as the window's (#250). */}
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
  );
});

/**
 * An archived project, with when it was put away, and Bring Back, as the window's
 * ArchivedProjectRow (#343). Brought back, it is a project again and its new-session form opens.
 */
function ArchivedProjectRow({ store, host, project, down }: {
  store: Store; host: ControlHost; project: ProjectSummary; down: boolean;
}) {
  const folder = project.project.folder;
  const archivedAt = project.project.archivedAt;
  const bringBack = async () => {
    if (await store.unarchiveProject(host.id, folder)) go({ host: host.id, project: folder, compose: true });
  };
  const menu: MenuItem[] = [{ label: "Bring Back", disabled: down, run: () => void bringBack() }];
  return (
    <div class="row archived-project" title={folderPath(folder)}
      onContextMenu={(e) => openContextMenu(e, menu)}>
      <span class="title">{project.name}</span>
      <button class="link" disabled={down} onClick={() => void bringBack()}
        onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, menu); }}>Bring Back</button>
      {archivedAt !== undefined && <span class="subtitle">Archived {namedRelative(fromWireDate(archivedAt))}</span>}
    </div>
  );
}

/**
 * One session's row under its project, drawn again only when the agent, whether it is chosen, or
 * its host's state changes, or something is on its way to it: not when its neighbours change.
 */
const SidebarSession = memo(function SidebarSession({ store, host, folder, agent, chosen, down, pinnedAt }: {
  store: Store; host: string; folder: string; agent: Agent; chosen: boolean; down: boolean;
  /** Under Pinned: the whole pinned order, for its Move Up and Move Down (#180). */
  pinnedAt?: string[] | undefined;
}) {
  const act = store.onItsWay.value[agent.id];
  const going = act && typeof act === "string" ? { doing: actDoing(act), recipient: store.recipient(host) } : undefined;
  const move = (by: number) => {
    const ids = [...(pinnedAt ?? [])];
    const at = ids.indexOf(agent.id);
    if (at < 0 || at + by < 0 || at + by >= ids.length) return;
    [ids[at], ids[at + by]] = [ids[at + by]!, ids[at]!];
    void store.arrangeSessionPins(host, folder, ids);
  };
  const menu = (): MenuItem[] => [
    ...sessionActions(agent, store.sessionPinsIn(host, folder).includes(agent.id)).map(({ action, label: words, help }) => ({
      label: words, help, disabled: down || !!store.onItsWay.value[agent.id],
      run: () => runSessionAction(store, host, agent, action),
    })),
    ...(pinnedAt ? [
      { label: "Move Up", disabled: down || pinnedAt[0] === agent.id, run: () => move(-1) },
      { label: "Move Down", disabled: down || pinnedAt[pinnedAt.length - 1] === agent.id, run: () => move(1) },
    ] : []),
  ];
  return (
    <div class="nav-item" onContextMenu={(e) => openContextMenu(e, menu())}
      onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, menu()); }}>
      <SessionRow agent={agent} chosen={chosen} onPick={() => go({ host, project: folder, session: agent.id })} going={going}
        waits={store.waitsOf(host, agent)} extras={rowExtras(store, host, agent)} />
    </div>
  );
});

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
    ".activity .row, .project-fold > .row.project .pick, .nav-item .row.pin .pick, .nav-item .row.session, .nav-item .row.workflow .pick, details.archived > summary, details.group > summary",
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
