// The page's one sidebar (#151), as the window's (#145, ProjectListView.swift) and the Remote's
// (RemoteSidebar.swift), and below 760 the root list, as the iPhone Remote's (#226, #235).
// Things-style since #495 (#499): New Session at the top, in the project last started in; Activity;
// then what wants the person across every project — Pinned, Needs You, Working, Unread — each drawn
// only with something in it (#507); then a group per project, its sessions newest started first
// with their state the row's mark, its workflows, and one Archived row opening a page; then the
// archived projects; and at the foot what the hosts and this browser are doing. Never more than two
// levels deep. No host headings: a server's project reads `host:Project`. A project's row only
// folds (#375).
//
// One list for the keys: ↑ and ↓ move through every row shown, opening what they land on, as the
// window's selection does; → unfolds a project or group and ← folds it, or steps out to its project
// from a row under it. The menu key, Shift-F10 or a right click opens a row's menu.
import { signal, useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import { actDoing, type Store } from "../model/store";
import { byStart, folderKey, projectFolder, showsUnread } from "../model/groups";
import { archiveAllHelp, archiveAllLabel } from "../model/archiveWords";
import { folds } from "../model/folds";
import { parseQuery, queryMatches, type LabelQuery } from "../model/labels";
import { newSessionProject, ownCount, pinnedSessions, pinnedWorkflows, projectSessions, rememberedProject, rememberProject,
  smartAgents, smartRows, smartTitles, withKept, type SmartRow } from "../model/sidebar";
import { namedRelative, workflowSummary } from "../model/workflows";
import { fromWireDate } from "../protocol/dates";
import type { Agent, ControlHost, ProjectSummary, WorkflowSummary } from "../protocol/generated";
import { go, route, type ActivityPage } from "../route";
import { browserName, type Session } from "../session";
import { ActivityRows } from "./Activity";
import { isMenuKey, openContextMenu, type MenuItem } from "./ContextMenu";
import { CloningRows, EmptyProjects, NewProjectMenu } from "./NewProject";
import { putFilesInDropbox, useDropboxDrop } from "./DropboxDialog";
import { rowExtras, SessionRow } from "./SessionRow";
import { runSessionAction, sessionActions } from "./SessionMenu";
import { WorkflowRow } from "./WorkflowRow";
import { PinnedPageRows } from "./Pins";
import { memo } from "../render/memo";

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
 * The pinned first, then the rest; each of the two this Mac's projects, then each server's, each
 * oldest added first, as the window's and the Remote's (SidebarOrder.projects, #250, #357): no
 * heading for a host.
 */
export function orderedProjects(hosts: ControlHost[], projects: Record<string, ProjectSummary[]>):
  { host: ControlHost; project: ProjectSummary }[] {
  const ordered = [...hosts.filter((h) => h.id === "mac"), ...hosts.filter((h) => h.id !== "mac")];
  const byHost = ordered.flatMap((host) => (projects[host.id] ?? [])
    .filter((project) => project.project.archivedAt === undefined)
    .sort(byAdded)
    .map((project) => ({ host, project })));
  return [...byHost.filter((r) => r.project.project.pinned === true),
          ...byHost.filter((r) => r.project.project.pinned !== true)];
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
  // Opened from Unread, a session stays there, read, until another is opened (#495), as a read
  // message stays in Mail's Unread mailbox while it is selected.
  useEffect(() => {
    const agent = r.host && r.session ? store.agent(r.host, r.session) : undefined;
    keptInUnread.value = agent && showsUnread(agent) ? { host: r.host!, id: agent.id } : null;
  }, [r.host, r.session]);
  // What is open, from anywhere (a link, Back), unfolds its project so its row is there to light,
  // unless an open group at the top already shows it.
  useEffect(() => {
    if (!r.host || !r.project || !(r.session || r.workflow || r.page || r.archive)) return;
    const agent = r.session ? store.agent(r.host, r.session) : undefined;
    if (agent && inOpenSmartRow(store, r.host, agent)) return;
    if (r.workflow && folds.isSmartOpen("pinned") && store.workflowPinsIn(r.host, r.project).includes(r.workflow)) return;
    folds.set(r.host, r.project, true);
  }, [r.host, r.project, r.session, r.workflow, r.page, r.archive]);
  // The next New Session at the top starts here too (#495).
  useEffect(() => {
    if (r.host && r.project && r.compose) rememberProject(storage, { host: r.host, folder: r.project });
  }, [r.host, r.project, r.compose]);
  const projects = orderedProjects(store.hosts.value, store.projects.value);
  const archived = archivedProjects(store.hosts.value, store.projects.value);
  const showsArchived = folds.showsArchivedProjects.value;
  const offline = store.hosts.value.filter((h) => h.state !== "online");
  const query = searched.value;
  return (
    <nav class="sidebar" aria-label="Sidebar">
      <header class="column-head sidebar-head">
        {/* The root list's title at a phone's width, as the iPhone's (#235). */}
        <h1 class="narrow-only">Agents</h1>
        <input class="search" type="search" placeholder="Search" aria-label="Search sessions and workflows"
          value={search.value} onInput={(e) => (search.value = (e.currentTarget as HTMLInputElement).value)} />
        {/* New project, which the window has in its File menu (#115): the page has no menu bar. */}
        <NewProjectMenu store={store} />
      </header>
      <div class="scroll" onKeyDown={(e) => moveWithKeys(e)}>
        {projects.length > 0 && <NewSessionTopRow store={store} projects={projects} linkDown={linkDown} />}
        {/* Pages about all the work rather than one project, above the smart groups, as the
            window's (#495). It folds, as a project does, and stays while searching, as the
            window's and the Remote's do (#547). */}
        <details class="activity" aria-label="Activity" open={folds.showsActivity.value}
          onToggle={(e) => folds.setShowsActivity((e.currentTarget as HTMLDetailsElement).open)}>
          <summary class="sidebar-head-label" data-fold="activity">Activity</summary>
          <ActivityRows store={store} chosen={r.activity} onPick={(page: ActivityPage) => go({ activity: page })} />
        </details>
        {/* Pinned, Needs You, Working, Unread, To Archive: a group each across every project and host (#495, #584). */}
        {projects.length > 0 && smartRows.map((row) => (
          <SmartFold key={row} row={row} store={store} projects={projects} query={query} linkDown={linkDown} />
        ))}
        {/* One group per project (#495), its name the group's heading, its sessions the rows. */}
        <section class="project-list" aria-label="Projects">
          {projects.map(({ host, project }) => (
            <ProjectFold key={`${host.id}|${project.project.folder}`} store={store} host={host} project={project}
              query={query} linkDown={linkDown} />
          ))}
          {/* A host had more matches than its page: the next page, on asking (#176). */}
          {query && Object.keys(store.searchNext.value).length > 0 && (
            <button class="link more-matches" onClick={() => void store.searchMore()}>More matches…</button>
          )}
          {store.hosts.value.map((host) => <CloningRows key={host.id} store={store} host={host.id} />)}
          <EmptyProjects store={store} />
        </section>
        {/* Projects put away, under their own heading, closed until opened, as the window's (#343). */}
        {!query && archived.length > 0 && (
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

// Through window, so a test without a page reads nothing (Node warns on a bare localStorage).
const storage = globalThis.window?.localStorage;

/** The session opened while it was unread, which Unread keeps until another is opened (#495). */
const keptInUnread = signal<{ host: string; id: string } | null>(null);

type Placed = { host: ControlHost; project: ProjectSummary };

/** One project's live sessions, every group's, as held. */
function liveSessions(store: Store, host: string, folder: string): Agent[] {
  return store.projectView(host, folder).headings.flatMap((h) => h.agents);
}

/** Whether a session is in sight under an open group at the top, so its project need not unfold. */
function inOpenSmartRow(store: Store, host: string, agent: Agent): boolean {
  if (folds.isSmartOpen("pinned") && store.sessionPinsIn(host, projectFolder(agent)).includes(agent.id)) return true;
  const kept = keptInUnread.peek();
  if (folds.isSmartOpen("unread") && kept?.host === host && kept.id === agent.id) return true;
  const pins = store.sessionPinsIn(host, projectFolder(agent));
  return (["needsYou", "working", "unread", "toArchive"] as const).some((row) => folds.isSmartOpen(row) && smartAgents(row, [agent], undefined, pins).length > 0);
}

/** A search narrows workflows by name and what they are; one asking for a label leaves them out. */
function workflowMatches(store: Store, host: string, query: LabelQuery | undefined): (w: WorkflowSummary) => boolean {
  if (!query) return () => true;
  const runtimeName = (id: string) => (store.runtimes.value[host] ?? []).find((s) => s.runtime.id === id)?.runtime.name;
  const text = query.text.toLowerCase();
  return (w) => query.label === null && (!text
    || [w.workflow.name, workflowSummary(w.workflow, runtimeName)].some((t) => t.toLowerCase().includes(text)));
}

/**
 * The first row of the sidebar (#495): a new session, in the project the last one was started in,
 * as the window's and the Remote's. Lit while that form is open. A project's menu starts one in
 * that project instead, and the form's project name switches to another.
 */
function NewSessionTopRow({ store, projects, linkDown }: { store: Store; projects: Placed[]; linkDown: boolean }) {
  const r = route.value;
  const live = projects.map(({ host, project }) => ({ host: host.id, folder: project.project.folder }));
  const open = r.host && r.project ? { host: r.host, folder: r.project } : undefined;
  const target = newSessionProject(live, rememberedProject(storage), open);
  const chosen = !!r.compose && !!target && r.host === target.host && r.project !== undefined
    && folderKey(r.project) === folderKey(target.folder);
  return (
    <div class="nav-item new-session-top">
      <div class={`row new-session${chosen ? " chosen" : ""}`}>
        <button class="pick" aria-current={chosen} disabled={linkDown || !target || !store.hostIsOnline(target.host)}
          onClick={() => target && go({ host: target.host, project: target.folder, compose: true })}>
          <span class="pin-mark" aria-hidden="true">✎</span>
          <span class="title">New Session</span>
        </button>
      </div>
    </div>
  );
}

/** A row under a group at the top: a session or a pinned workflow, with the project it is in. */
type SmartLine = Placed & ({ kind: "session"; agent: Agent } | { kind: "workflow"; summary: WorkflowSummary })
  & { pins?: string[] | undefined };

/**
 * One of the groups at the top of the sidebar (#495): Pinned, Needs You, Working, Unread or To
 * Archive (#584), across every project and host, each row naming its project. To Archive's head has
 * Archive All, for every session it gathers, whatever a search shows. Drawn only with something in it, and while
 * searching only with a match (#507); Unread still is while it keeps the open session. Folded, it
 * lists nothing but counts.
 */
function SmartFold({ row, store, projects, query, linkDown }: {
  row: SmartRow; store: Store; projects: Placed[]; query: string; linkDown: boolean;
}) {
  const r = route.value;
  const parsed = query ? parseQuery(query) : undefined;
  // Pinned workflows of folded projects are listed too, held while Pinned is drawn (#432).
  const flowPinned = row !== "pinned" ? [] : projects.filter(({ host, project }) =>
    store.hostIsOnline(host.id) && store.workflowPinsIn(host.id, project.project.folder).length > 0);
  const holding = flowPinned.map(({ host, project }) => `${host.id}|${project.project.folder}`).join("\n");
  useEffect(() => {
    const held = flowPinned.map(({ host, project }) => ({ host: host.id, folder: project.project.folder }));
    for (const p of held) store.holdWorkflows(p.host, p.folder);
    return () => { for (const p of held) store.releaseWorkflows(p.host, p.folder); };
  }, [holding]);

  const open = folds.isSmartOpen(row);
  let count = 0;
  let lines: SmartLine[] = [];
  let keptPlace: Placed | undefined;
  const asking: { host: string; agentID: string }[] = [];
  if (row === "pinned") {
    for (const placed of projects) {
      const host = placed.host.id;
      const folder = placed.project.project.folder;
      const pins = store.sessionPinsIn(host, folder);
      const flowPins = store.workflowPinsIn(host, folder);
      if (!pins.length && !flowPins.length) continue;
      const live = liveSessions(store, host, folder);
      const flows = pinnedWorkflows(store.projectWorkflows(host, folder), flowPins);
      count += pinnedSessions(live, pins).length + flows.length;
      // The whole order for Move Up and Down, which a search shows only some of.
      lines.push(...pinnedSessions(live, pins, parsed)
        .map((agent): SmartLine => ({ ...placed, kind: "session", agent, pins: parsed ? undefined : pins })));
      lines.push(...flows.filter(workflowMatches(store, host, parsed))
        .map((summary): SmartLine => ({ ...placed, kind: "workflow", summary, pins: parsed ? undefined : flowPins })));
    }
  } else {
    const found = new Map<Agent, Placed>();
    for (const placed of projects) {
      const live = liveSessions(store, placed.host.id, placed.project.project.folder);
      // The pinned are in Pinned alone: each session is listed once (#587).
      const pins = store.sessionPinsIn(placed.host.id, placed.project.project.folder);
      const gathered = smartAgents(row, live, undefined, pins);
      count += gathered.length;
      if (row === "toArchive") asking.push(...gathered.map((a) => ({ host: placed.host.id, agentID: a.id })));
      if (open || parsed) for (const agent of smartAgents(row, live, parsed, pins)) found.set(agent, placed);
    }
    // Unread keeps the session opened from it in its place, read now; none while searching.
    const kept = row === "unread" && !parsed ? keptInUnread.value : null;
    const keptAgent = kept ? store.agent(kept.host, kept.id) : undefined;
    keptPlace = keptAgent && keptAgent.state !== "archived" ? projects.find(({ host, project }) =>
      host.id === kept!.host && folderKey(project.project.folder) === projectFolder(keptAgent)) : undefined;
    lines = withKept([...found.keys()].sort(byStart), keptPlace ? keptAgent : undefined)
      .map((agent): SmartLine => ({ ...(found.get(agent) ?? keptPlace!), kind: "session", agent }));
  }
  if (parsed ? lines.length === 0 : count === 0 && !keptPlace) return null;
  const title = smartTitles[row];
  return (
    <details class={`smart ${row}`} role="group" aria-label={title} open={open}
      onToggle={(e) => {
        const now = (e.currentTarget as HTMLDetailsElement).open;
        if (now !== open) folds.setSmart(row, now);
      }}>
      <summary class="sidebar-head-label" data-fold={`smart.${row}`} aria-label={count > 0 ? `${title}, ${count}` : `${title}, none`}>
        {title}
        {row === "toArchive" && count > 0 && (
          // Its own click, not the fold's.
          <button class="archive-all" title={archiveAllHelp(count)} disabled={linkDown}
            onClick={(e) => { e.preventDefault(); e.stopPropagation(); void store.archiveAll(asking); }}>{archiveAllLabel}</button>
        )}
        {count > 0 && <span class={`count${row === "needsYou" ? " needs" : ""}`}>{count}</span>}
      </summary>
      {open && lines.map((line) => {
        const host = line.host.id;
        const folder = line.project.project.folder;
        const down = linkDown || !store.hostIsOnline(host);
        const place = projectLabel(line.host, line.project);
        return line.kind === "session" ? (
          <SidebarSession key={`${host}|${line.agent.id}`} store={store} host={host} folder={folder} agent={line.agent}
            chosen={r.host === host && r.session === line.agent.id} down={down} pinnedAt={line.pins} place={place} />
        ) : (
          <div class="nav-item" key={`${host}|${line.summary.workflow.workflowID}`}>
            <WorkflowRow store={store} host={host} summary={line.summary} disabled={down} place={place}
              chosen={r.host === host && r.workflow === line.summary.workflow.workflowID} pinnedAt={line.pins}
              onPick={() => go({ host, project: folder, workflow: line.summary.workflow.workflowID })} />
          </div>
        );
      })}
    </details>
  );
}

/**
 * One project (#495): a group headed by its row, then its pinned pages, its live sessions newest
 * started first with their state the row's mark, its workflows, and one Archived row opening a
 * page. Its pinned sessions and workflows are in Pinned at the top. A search unfolds every project
 * with something that matches, its archived matches inline, and hides the rest. It reads its own
 * project's agents alone, so a change to an agent draws one fold again, and a folded one reads
 * nothing of its sessions (#170). `query` is the search's words, already trimmed.
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
  // Every match on show, past the first few; a new search shows the few again.
  const showsAllMatches = useSignal(false);
  useEffect(() => { showsAllMatches.value = false; }, [query]);
  const online = store.hostIsOnline(host.id);
  // A file dragged onto the row goes into the project's drop box (#231). Before any early return:
  // it is a hook.
  const drop = useDropboxDrop(store, host.id, folder, down);
  // The list is held while the project is open, and let go when it folds (#291).
  useEffect(() => {
    if (!unfolded || !online) return;
    store.holdWorkflows(host.id, folder);
    return () => store.releaseWorkflows(host.id, folder);
  }, [unfolded, online, host.id, folder]);

  const view = store.projectView(host.id, folder);
  // The matcher is made once per fold, not per row.
  const parsed = searching ? parseQuery(query) : undefined;
  const live = view.headings.flatMap((h) => h.agents);
  // Those a group at the top lists are there alone (#495, #587), out of the project's list.
  const pins = store.sessionPinsIn(host.id, folder);
  const sessions = !unfolded ? [] : projectSessions(live, pins, parsed);
  // The heading's grey count, as every group's heading has one (#587), folded or not.
  const own = ownCount(live, pins);
  const archived = !unfolded || !parsed ? [] : view.archived.filter((a) => queryMatches(parsed, a));
  const allWorkflows = (unfolded ? store.projectWorkflows(host.id, folder) : [])
    .filter(workflowMatches(store, host.id, parsed))
    .sort((a, b) => a.workflow.name.localeCompare(b.workflow.name));
  const flowPins = store.workflowPinsIn(host.id, folder);
  const workflows = allWorkflows.filter((w) => !w.isArchived && !flowPins.includes(w.workflow.workflowID));
  const archivedWorkflows = allWorkflows.filter((w) => w.isArchived);
  const nameMatches = label.toLowerCase().includes(query.toLowerCase());
  if (searching && sessions.length === 0 && archived.length === 0 && workflows.length === 0
    && archivedWorkflows.length === 0 && !nameMatches) return null;

  const here = r.host === host.id && r.project !== undefined && folderKey(r.project) === folderKey(folder);
  const archiveCount = (project.counts.archived ?? 0) + archivedWorkflows.length;
  const fold = (open: boolean) => folds.set(host.id, folder, open);
  const projectPinned = project.project.pinned === true;
  const projectMenu: MenuItem[] = [
    { label: "New Session", disabled: down, help: "Start a new session in this project",
      run: () => go({ host: host.id, project: folder, compose: true }) },
    { label: "Put Files in Drop Box…", disabled: down, help: "Put files into this project's .agents/dropbox/ (#231)",
      run: () => putFilesInDropbox(host.id, folder, label) },
    // To the top of the sidebar, as the window's Pin.
    { label: projectPinned ? "Unpin" : "Pin", disabled: down,
      help: projectPinned ? "Let this project take its place among the others" : "Keep this project at the top of the sidebar",
      run: () => void store.setProjectPinned(host.id, folder, !projectPinned) },
  ];
  const row = (agent: Agent) => (
    <SidebarSession key={agent.id} store={store} host={host.id} folder={folder} agent={agent}
      chosen={r.host === host.id && r.session === agent.id} down={down} />
  );
  const workflowRow = (summary: WorkflowSummary) => (
    <div class="nav-item" key={summary.workflow.workflowID}>
      <WorkflowRow store={store} host={host.id} summary={summary} disabled={down}
        chosen={here && r.workflow === summary.workflow.workflowID}
        onPick={() => go({ host: host.id, project: folder, workflow: summary.workflow.workflowID })} />
    </div>
  );
  return (
    <div class={`project-fold${down && !linkDown ? " greyed" : ""}`} role="group" aria-label={label}
      data-host={host.id} data-folder={folder}>
      <div class={`row project${drop.targeted ? " drop-target" : ""}`} {...drop.props}>
        <button class="disclosure" aria-label={unfolded ? `Fold ${label}` : `Unfold ${label}`} aria-expanded={unfolded}
          tabIndex={-1} disabled={searching} onClick={() => fold(!unfolded)}>{unfolded ? "⌄" : "›"}</button>
        <button class="pick" aria-expanded={unfolded} data-fold="project" title={folderPath(folder)}
          onClick={(e) => {
            // The row folds or unfolds, and nothing else (#375): a session starts from New Session
            // at the top. Not when the arrow keys land here (a click with no detail): moving
            // through the list folds nothing.
            if (e.detail > 0 && !searching) fold(!unfolded);
          }}
          onContextMenu={(e) => openContextMenu(e, projectMenu)}
          onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, projectMenu); }}>
          <span class="title">{project.isChat === true && <span class="project-chat" aria-label="chat project">💬 </span>}{label}{projectPinned && <span class="project-pin" aria-label="pinned"> 📌</span>}</span>
          {/* A heading, as the groups' at the top (#587): who needs you is in Needs You, so no
              line under it and no dot; only a missing folder is said. */}
          {!project.exists && <span class="subtitle">Folder is missing</span>}
        </button>
        {own > 0 && <span class="count" aria-label={`${own} sessions`}>{own}</span>}
      </div>
      {unfolded && (
        <div class="fold-body">
          {/* The project's pinned pages first (#159), not while searching: the search is for sessions. */}
          {!searching && <PinnedPageRows store={store} host={host.id} folder={folder} down={down} chosen={here ? r.page : undefined} />}
          {sessions.map(row)}
          {/* Its workflows after the sessions (#495): rows, not a page. */}
          {workflows.map(workflowRow)}
          {searching ? <>
            {/* What matched in the archive, in the group while searching, so a match is one click away. */}
            {archivedWorkflows.map(workflowRow)}
            {archived.slice(0, showsAllMatches.value ? archived.length : matchesShown).map(row)}
            {!showsAllMatches.value && archived.length > matchesShown && (
              <button class="link show-all" onClick={() => (showsAllMatches.value = true)}>Show all {archived.length}</button>
            )}
          </> : archiveCount > 0 && (
            // The archive, one row opening a page (#495): never a fold inside the group.
            <div class="nav-item">
              <div class={`row page-row${here && r.archive ? " chosen" : ""}`}>
                {/* Nothing at its end, which is only a session's (#587): the count is its tooltip's. */}
                <button class="pick" aria-current={here && !!r.archive} aria-label={`Archived, ${archiveCount}`}
                  title={`${archiveCount} archived`} onClick={() => go({ host: host.id, project: folder, archive: true })}>
                  <span class="pin-mark" aria-hidden="true">▣</span>
                  <span class="title">Archived</span>
                </button>
              </div>
            </div>
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
 * One session's row in the sidebar, drawn again only when the agent, whether it is chosen, or its
 * host's state changes, or something is on its way to it: not when its neighbours change.
 */
export const SidebarSession = memo(function SidebarSession({ store, host, folder, agent, chosen, down, pinnedAt, place }: {
  store: Store; host: string; folder: string; agent: Agent; chosen: boolean; down: boolean;
  /** Under Pinned: the whole pinned order, for its Move Up and Move Down (#180). */
  pinnedAt?: string[] | undefined;
  /** Under a group at the top, which gathers every project's: its project's name (#495). */
  place?: string | undefined;
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
  // Into its project's drop box, never its worktree (#231).
  const drop = useDropboxDrop(store, host, folder, down);
  return (
    <div class={`nav-item${drop.targeted ? " drop-target" : ""}`} onContextMenu={(e) => openContextMenu(e, menu())}
      onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, menu()); }} {...drop.props}>
      {/* No wait lines: in the sidebar a session's row is its title and one line (#587). */}
      <SessionRow agent={agent} chosen={chosen} onPick={() => go({ host, project: folder, session: agent.id })} going={going}
        extras={rowExtras(store, host, agent)}
        inSidebar place={place} />
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
    ".new-session-top .pick, .activity .row, details.smart > summary, .project-fold > .row.project .pick, .nav-item .row.pin .pick, .nav-item .row.session, .nav-item .row.workflow .pick, .nav-item .row.page-row .pick, details.archived > summary",
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
