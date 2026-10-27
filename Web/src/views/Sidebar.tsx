// The page's one sidebar (#151), as the window's (#145, FolderListView.swift) and the Remote's
// (RemoteSidebar.swift), and below 760 the root list, as the iPhone Remote's (#226, #235).
// Things-style since #495 (#499): New Session at the top, in the folder last started in; Activity;
// then what wants the person across every folder — Pinned, Needs You, Working, Unread — each drawn
// only with something in it (#507), Needs You with what waits for an OK after its sessions (#773); then a group per folder, its sessions newest started first
// with their state the row's mark, its Workflows fold (#885), and one Archived row opening a page; then the
// archived folders; and at the foot what the hosts and this browser are doing, and Settings (#846),
// where each smart group can be turned off. Never more than three
// levels deep: a folder's Workflows fold (#885) is the third. No host headings: a server's folder reads `host:Folder`. A folder's row only
// folds (#375).
//
// One list for the keys: ↑ and ↓ move through every row shown, opening what they land on, as the
// window's selection does; → unfolds a folder or group and ← folds it, or steps out to its folder
// from a row under it. The menu key, Shift-F10 or a right click opens a row's menu.
import { undoLabel, undoMillis } from "../model/archiveWords";
import { healthTally, folderServers } from "../model/hostedMCP";
import { signal, useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import { ProjectAgentConfigModal } from "./AgentConfigEditor";
import { actDoing, type Store } from "../model/store";
import { byStart, folderKey, folderPath as agentFolderPath, showsUnread } from "../model/groups";
import { folds } from "../model/folds";
import { smartGroupsOn } from "../model/smartGroups";
import { macHostNoticeDetail, macHostNoticeTitle } from "../model/macHostNotice";
import { hostAnswers } from "../model/capabilities";
import { Capability } from "../protocol/capabilities.generated";
import { parseQuery, queryMatches, type LabelQuery } from "../model/labels";
import { keepsInUnread, newSessionFolder, pinnedSessions, pinnedWorkflows, folderSessions, rememberedFolder, rememberFolder,
  smartAgents, smartApprovals, smartRows, smartTitles, withKept, type FolderKey, type SmartRow } from "../model/sidebar";
import { updatedLine } from "../model/updated";
import { namedRelative, workflowSummary } from "../model/workflows";
import { fromWireDate } from "../protocol/dates";
import type { Agent, AgentsExportRequest, ControlHost, FolderSummary, WorkflowSummary } from "../protocol/generated";
import { alone, aloneURL, go, route, showAll, type ActivityPage } from "../route";
import { onThisMac } from "../place";
import { browserName, type Session } from "../session";
import { ActivityRows } from "./Activity";
import { holdForMenu, isMenuKey, openContextMenu, type MenuItem } from "./ContextMenu";
import { CloningRows, EmptyFolders, NewFolderMenu } from "./NewFolder";
import { putFilesInDropbox, useDropboxDrop } from "./DropboxDialog";
import { exportFromMenu, importFromMenu } from "../model/exports";
import { rowExtras, SessionRow } from "./SessionRow";
import { openInNewTab, RenameInput, runSessionAction, sessionActions, startedBy } from "./SessionMenu";
import { markAgentOf, treeRows, type TreeRow } from "../model/tree";
import { WorkflowRow } from "./WorkflowRow";
import { footLine, offersStart } from "./OfflineStrip";
import { PinnedPageRows, ServerViewRows, showHiddenViewsItem } from "./Pins";
import { ApprovalRow, FailedWorkflowRow } from "./Approval";
import { JoinRequests } from "./JoinRequest";
import { LinkRequests } from "./ChannelLinks";
import { SignInRequests } from "./SignInRequests";
import { approvalID, failedRuns, opensItsSubject } from "../model/approvals";
import { memo } from "../render/memo";

/** The docs site: the guides and the statuses reference (#1327), as the window's Help ▸ Agents Help. */
const helpSite = "https://docs.agentloops.dev/";

/** The most archived matches a fold shows before Show all, as the window's (#176). */
const matchesShown = 10;

/** How long the typing pauses before the folds filter and the hosts are asked (#176). */
export const searchPause = 150;

/** A folder's name in the sidebar: `host:Folder` on a server, the name alone on this Mac (`macID`, #1501). */
export function folderLabel(host: ControlHost | undefined, folder: FolderSummary, macID = "mac"): string {
  return !host || host.id === macID ? folder.name : `${host.name}:${folder.name}`;
}

/**
 * Oldest added first, then by folder, as the window's and the Remote's (SidebarOrder.byAdded,
 * #357): a row stays where it is however busy its folder is, and a new folder lands at the end.
 */
export function byAdded(a: FolderSummary, b: FolderSummary): number {
  if (a.folder.addedAt !== b.folder.addedAt) return a.folder.addedAt - b.folder.addedAt;
  const [x, y] = [folderKey(a.folder.folder), folderKey(b.folder.folder)];
  return x < y ? -1 : x > y ? 1 : 0;
}

/**
 * The pinned first, then the rest; each of the two this Mac's folders, then each server's, each
 * oldest added first, as the window's and the Remote's (SidebarOrder.folders, #250, #357): no
 * heading for a host.
 */
export function orderedFolders(hosts: ControlHost[], folders: Record<string, FolderSummary[]>, macID = "mac"):
  { host: ControlHost; folder: FolderSummary }[] {
  const ordered = [...hosts.filter((h) => h.id === macID), ...hosts.filter((h) => h.id !== macID)];
  const byHost = ordered.flatMap((host) => (folders[host.id] ?? [])
    .filter((folder) => folder.folder.archivedAt === undefined)
    .sort(byAdded)
    .map((folder) => ({ host, folder })));
  return [...byHost.filter((r) => r.folder.folder.pinned === true),
          ...byHost.filter((r) => r.folder.folder.pinned !== true)];
}

/** Every host's archived folders, the latest archived first (#2153), as the window's Archived folders (#343). */
export function archivedFolders(hosts: ControlHost[], folders: Record<string, FolderSummary[]>):
  { host: ControlHost; folder: FolderSummary }[] {
  return hosts.flatMap((host) => (folders[host.id] ?? [])
    .filter((folder) => folder.folder.archivedAt !== undefined)
    .map((folder) => ({ host, folder })))
    .sort((a, b) => (b.folder.folder.archivedAt ?? b.folder.lastActivityAt) - (a.folder.folder.archivedAt ?? a.folder.lastActivityAt));
}

export function Sidebar({ session, store, linkDown }: { session: Session; store: Store; linkDown: boolean }) {
  const search = useSignal("");
  // What the folds filter by: the field's words once typing pauses, so a keystroke costs the
  // field and not a pass over every folder (#176, #193).
  const searched = useSignal("");
  const confirming = useSignal(false);
  // Why Forget This Browser did not forget it, under the confirm, as the Remote's (#935).
  const forgetProblem = useSignal<string | null>(null);
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
  // What is open, from anywhere (a link, Back), unfolds its folder so its row is there to light,
  // unless an open group at the top already shows it.
  useEffect(() => {
    if (!r.host || !r.folder || !(r.session || r.workflow || r.page || r.archive || r.mcp)) return;
    const agent = r.session ? store.agent(r.host, r.session) : undefined;
    if (agent && inOpenSmartRow(store, r.host, agent)) return;
    if (r.workflow && smartGroupsOn.peek().has("pinned") && folds.isSmartOpen("pinned") && store.workflowPinsIn(r.host, r.folder).includes(r.workflow)) return;
    folds.set(r.host, r.folder, true);
  }, [r.host, r.folder, r.session, r.workflow, r.page, r.archive, r.mcp]);
  // The next New Session at the top starts here too (#495).
  useEffect(() => {
    if (r.host && r.folder && r.compose) rememberFolder(storage, { host: r.host, folder: r.folder });
  }, [r.host, r.folder, r.compose]);
  // A tab holding one folder alone (#1089): its sidebar is that folder's only.
  const held = alone.value;
  const every = orderedFolders(store.hosts.value, store.folders.value, store.macHostID.value);
  const folders = held ? every.filter(({ host, folder }) => host.id === held.host
    && folderKey(folder.folder.folder) === folderKey(held.folder)) : every;
  const archived = held ? [] : archivedFolders(store.hosts.value, store.folders.value);
  const showsArchived = folds.showsArchivedFolders.value;
  const offline = store.hosts.value.filter((h) => !hostAnswers(h.state));
  const macHost = store.hosts.value.find((h) => h.id === store.macHostID.value);
  const macNotice = store.macHostNotice.value;
  const query = searched.value;
  return (
    <nav class="sidebar" aria-label="Sidebar">
      <header class="column-head sidebar-head">
        {/* The root list's title at a phone's width, as the iPhone's (#235). */}
        {held ? <>
          <button class="link back-all" aria-label="All folders" onClick={showAll}>‹ All</button>
          <h1 class="alone-title">{folders[0] ? folderLabel(folders[0].host, folders[0].folder, store.macHostID.value) : "Folder"}</h1>
        </> : <h1 class="narrow-only">Agents</h1>}
        <input class="search" type="search" placeholder="Search" aria-label="Search sessions and workflows"
          value={search.value} onInput={(e) => (search.value = (e.currentTarget as HTMLInputElement).value)} />
        {/* New folder, which the window has in its File menu (#115): the page has no menu bar. */}
        <NewFolderMenu store={store} newSession={newSessionStart(store, folders, linkDown)} />
      </header>
      <div class="scroll" onKeyDown={(e) => moveWithKeys(e)}>
        {folders.length > 0 && <NewSessionTopRow store={store} folders={folders} linkDown={linkDown} />}
        {/* A machine asking to join (#994): at the top, whatever groups are on, and with no folder yet. */}
        {!held && <JoinRequests store={store} down={linkDown} />}
        {/* A channel identity asking to act as this person (#1762), beside the machines. */}
        {!held && <LinkRequests store={store} down={linkDown} />}
        {/* A new client that signed in with GitHub as this person (#995), beside them. */}
        {!held && <SignInRequests store={store} down={linkDown} />}
        {/* Pages about all the work rather than one folder, above the smart groups, as the
            window's (#495): Status, what goes on now, and Usage, the past (#915). Each folds, as
            a folder does, and stays while searching, as the window's and the Remote's do (#547). */}
        {!held && <>
        <details class="activity" aria-label="Status" open={folds.showsStatus.value}
          onToggle={(e) => folds.setShowsStatus((e.currentTarget as HTMLDetailsElement).open)}>
          <summary class="sidebar-head-label" data-fold="status">Status</summary>
          <ActivityRows group="status" store={store} chosen={r.activity} onPick={(page: ActivityPage) => go({ activity: page })} />
        </details>
        <details class="activity" aria-label="Usage" open={folds.showsUsage.value}
          onToggle={(e) => folds.setShowsUsage((e.currentTarget as HTMLDetailsElement).open)}>
          <summary class="sidebar-head-label" data-fold="usage">Usage</summary>
          <ActivityRows group="usage" store={store} chosen={r.activity} onPick={(page: ActivityPage) => go({ activity: page })} />
        </details>
        </>}
        {/* Pinned, Needs You, Working, Unread: a group each across every folder and host (#495, #773),
            each that is on in this browser's Settings (#846). */}
        {folders.length > 0 && smartRows.filter((row) => smartGroupsOn.value.has(row) && (!held || aloneRows.has(row))).map((row) => (
          <SmartFold key={row} row={row} store={store} folders={folders} query={query} linkDown={linkDown}
            downSince={session.state.value.kind === "down" ? session.state.value.since : undefined} />
        ))}
        {/* One group per folder (#495), its name the group's heading, its sessions the rows. */}
        <section class="folder-list" aria-label="Folders">
          {folders.map(({ host, folder }) => (
            <FolderFold key={`${host.id}|${folder.folder.folder}`} store={store} host={host} folder={folder}
              query={query} linkDown={linkDown} alone={!!held} />
          ))}
          {held && <Elsewhere store={store} folders={every.filter((p) => !folders.includes(p))} />}
          {/* A host had more matches than its page: the next page, on asking (#176). */}
          {query && Object.keys(store.searchNext.value).length > 0 && (
            <button class="link more-matches" onClick={() => void store.searchMore()}>More matches…</button>
          )}
          {store.hosts.value.map((host) => <CloningRows key={host.id} store={store} host={host.id} />)}
          <EmptyFolders store={store} />
        </section>
        {/* Folders put away, under their own heading, closed until opened, as the window's (#343). */}
        {!query && archived.length > 0 && (
          <details class="archived archived-folders" open={showsArchived}
            onToggle={(e) => folds.setShowsArchivedFolders((e.currentTarget as HTMLDetailsElement).open)}>
            <summary class="sidebar-head-label" data-fold="archivedFolders">Archived folders</summary>
            {showsArchived && archived.map(({ host, folder }) => (
              <ArchivedFolderRow key={`${host.id}|${folder.folder.folder}`} store={store} host={host} folder={folder}
                down={linkDown || !store.hostIsOnline(host.id)} />
            ))}
          </details>
        )}
      </div>
      {/* What the hosts and this browser are doing, pinned at the foot: status lines rather than
          somewhere to go. Each is absent when there is nothing to say. */}
      <footer class="sidebar-foot">
        <ArchiveUndoStrip store={store} />
        {/* This Mac's host: still connecting is said as the window says it, not as down (#250); down,
            why, in the window's words, when the control plane knows (#666). */}
        {macNotice && (macHost?.state === "connecting" && macNotice.kind === "notAnswering" ? (
          <p class="foot-line quiet" role="status">Connecting…</p>
        ) : (
          <div class="host-down" role="status">
            <p class="strong">⚠︎ {macHostNoticeTitle(macNotice)}</p>
            <p class="quiet small">{macHostNoticeDetail(macNotice)}</p>
          </div>
        ))}
        {offline.filter((host) => !store.isMac(host.id)).map((host) => (
          <p class="foot-line" role="status" key={host.id}>
            <span aria-hidden="true">⚡︎</span> {footLine(host)}
            {/* One on a stopped workspace offers Start, as its strip (#961). */}
            {host.workspace && offersStart(host.state, host.workspace) ? (
              <button type="button" class="foot-start" disabled={store.hostsBeingStarted.value.includes(host.id)}
                aria-label={`Start ${host.name}`} onClick={() => void store.startHost(host.id)}>Start</button>
            ) : null}
          </p>
        ))}
        {/* A file a host keeps that could not be read (#205, #223): why paired devices or folders
            may have gone from view, and that what they held is kept. A server's are named. */}
        {store.hosts.value.flatMap((host) => (store.storeNotes.value[host.id] ?? []).map((note) => (
          <p class="foot-line store-note" role="status" key={`${host.id}|${note}`}>
            <span aria-hidden="true">⚠︎</span> {store.isMac(host.id) ? note : `${host.name}: ${note}`}
          </p>
        )))}
        <div class="identity">
          <span>{browserName()} {onThisMac() ? "on this Mac" : "on the web"}</span>
          {/* This browser's Settings (#846): which smart groups are on, as the window's
              Settings ▸ Sidebar. */}
          <button class="link" aria-current={!!r.settings} onClick={() => go({ settings: true })}>Settings</button>
          {/* The docs site (#1327), as the window's Help ▸ Agents Help. */}
          <a class="link" href={helpSite} target="_blank" rel="noopener">Help</a>
          {/* What forgetting does, beside the confirm, in the Remote's words (#935). */}
          {confirming.value ? (
            <div class="forget" role="group" aria-label="Forget This Browser">
              <p class="small">This browser is cut off at once, at home and away, until it is paired again.</p>
              <span class="confirm">
                <button onClick={() => {
                  forgetProblem.value = null;
                  void session.forgetThisBrowser().then((problem) => (forgetProblem.value = problem));
                }}>Forget</button>
                <button onClick={() => { confirming.value = false; forgetProblem.value = null; }}>Cancel</button>
              </span>
            </div>
          ) : (
            <button class="link" onClick={() => (confirming.value = true)}>Forget This Browser…</button>
          )}
          {forgetProblem.value && <p class="failure small" role="alert">{forgetProblem.value}</p>}
        </div>
      </footer>
    </nav>
  );
}

// Through window, so a test without a page reads nothing (Node warns on a bare localStorage).
const storage = globalThis.window?.localStorage;

/** The session opened while it was unread, which Unread keeps until another is opened (#495). */
const keptInUnread = signal<{ host: string; id: string } | null>(null);

type Placed = { host: ControlHost; folder: FolderSummary };

/** One folder's live sessions, every group's, as held. */
/** Who started a session, on whichever host holds it: a smart group gathers every host's (#835). */
function startedByOf(store: Store, id: string): string | undefined {
  for (const agents of Object.values(store.agents.value)) {
    const found = agents?.find((a) => a.id === id);
    if (found) return found.startedByAgent;
  }
  return undefined;
}

function liveSessions(store: Store, host: string, folder: string): Agent[] {
  return store.folderView(host, folder).headings.flatMap((h) => h.agents);
}

/** Whether a session is in sight under an open group at the top, so its folder need not unfold. */
function inOpenSmartRow(store: Store, host: string, agent: Agent): boolean {
  const on = smartGroupsOn.peek();
  const pins = store.sessionPinsIn(host, agentFolderPath(agent));
  if (on.has("pinned") && folds.isSmartOpen("pinned") && pins.includes(agent.id)) return true;
  const kept = keptInUnread.peek();
  if (on.has("unread") && folds.isSmartOpen("unread") && kept?.host === host && kept.id === agent.id) return true;
  return (["needsYou", "working", "unread"] as const).some((row) => folds.isSmartOpen(row) && smartAgents(row, [agent], undefined, pins, on).length > 0);
}

/** A search narrows workflows by name and what they are; one asking for a label leaves them out. */
function workflowMatches(store: Store, host: string, query: LabelQuery | undefined): (w: WorkflowSummary) => boolean {
  if (!query) return () => true;
  const runtimeName = (id: string) => (store.runtimes.value[host] ?? []).find((s) => s.runtime.id === id)?.runtime.name;
  const text = query.text.toLowerCase();
  return (w) => query.label === null && (!text
    || [w.workflow.name, workflowSummary(w.workflow, runtimeName)].some((t) => t.toLowerCase().includes(text)));
}

/** New Session in the + menu (#628): its start, or undefined while there is nowhere to start one. */
function newSessionStart(store: Store, folders: Placed[], linkDown: boolean): (() => void) | undefined {
  const target = newSessionTarget(folders);
  if (linkDown || !target || !store.hostIsOnline(target.host)) return undefined;
  return () => go({ host: target.host, folder: target.folder, compose: true });
}

/** The folder New Session starts in, at the top of the sidebar and in the + menu (#628). */
function newSessionTarget(folders: Placed[]): FolderKey | undefined {
  const r = route.value;
  const live = folders.map(({ host, folder }) => ({ host: host.id, folder: folder.folder.folder }));
  const open = r.host && r.folder ? { host: r.host, folder: r.folder } : undefined;
  return newSessionFolder(live, rememberedFolder(storage), open);
}

/**
 * The first row of the sidebar (#495): a new session, in the folder the last one was started in,
 * as the window's and the Remote's. Lit while that form is open. A folder's menu starts one in
 * that folder instead, and the form's folder name switches to another.
 */
function NewSessionTopRow({ store, folders, linkDown }: { store: Store; folders: Placed[]; linkDown: boolean }) {
  const r = route.value;
  const target = newSessionTarget(folders);
  const chosen = !!r.compose && !!target && r.host === target.host && r.folder !== undefined
    && folderKey(r.folder) === folderKey(target.folder);
  return (
    <div class="nav-item new-session-top">
      <div class={`row new-session${chosen ? " chosen" : ""}`}>
        <button class="pick" aria-current={chosen} disabled={linkDown || !target || !store.hostIsOnline(target.host)}
          onClick={() => target && go({ host: target.host, folder: target.folder, compose: true })}>
          <span class="pin-mark" aria-hidden="true">✎</span>
          <span class="title">New Session</span>
        </button>
      </div>
    </div>
  );
}

/** A row under a group at the top: a session or a pinned workflow, with the folder it is in. */
type SmartLine = Placed & ({ kind: "session"; agent: Agent } | { kind: "workflow"; summary: WorkflowSummary })
  & { pins?: string[] | undefined; tree?: TreeRow | undefined };

/**
 * One of the groups at the top of the sidebar (#495): Pinned, Needs You, Working or Unread, across
 * every folder and host, each row naming its folder. Needs You lists the sessions asking, blocked or
 * asking to be archived (#584, #773), then what waits for an OK, oldest first, each answered from its
 * own sheet (no Approve All, #704); its count is of both. Drawn only with something in it, and while
 * searching only with a match (#507); Unread still is while it keeps the open session. Folded, it
 * lists nothing but counts.
 */
function SmartFold({ row, store, folders, query, linkDown, downSince }: {
  row: SmartRow; store: Store; folders: Placed[]; query: string; linkDown: boolean;
  /** When the link was lost: Needs You says its count was last true then (#1163). */
  downSince?: number | undefined;
}) {
  const r = route.value;
  const parsed = query ? { ...parseQuery(query), said: store.saidLines.value } : undefined;
  // Pinned workflows of folded folders are listed too, held while Pinned is drawn (#432).
  const flowPinned = row !== "pinned" ? [] : folders.filter(({ host, folder }) =>
    store.hostIsOnline(host.id) && store.workflowPinsIn(host.id, folder.folder.folder).length > 0);
  const holding = flowPinned.map(({ host, folder }) => `${host.id}|${folder.folder.folder}`).join("\n");
  useEffect(() => {
    const held = flowPinned.map(({ host, folder }) => ({ host: host.id, folder: folder.folder.folder }));
    for (const p of held) store.holdWorkflows(p.host, p.folder);
    return () => { for (const p of held) store.releaseWorkflows(p.host, p.folder); };
  }, [holding]);

  const open = folds.isSmartOpen(row);
  // The groups on (#846): one off passes its sessions to the next they fit.
  const on = smartGroupsOn.value;
  let count = 0;
  let lines: SmartLine[] = [];
  let keptPlace: Placed | undefined;
  if (row === "pinned") {
    for (const placed of folders) {
      const host = placed.host.id;
      const folder = placed.folder.folder.folder;
      const pins = store.sessionPinsIn(host, folder);
      const flowPins = store.workflowPinsIn(host, folder);
      if (!pins.length && !flowPins.length) continue;
      const live = liveSessions(store, host, folder);
      const flows = pinnedWorkflows(store.folderWorkflows(host, folder), flowPins);
      count += pinnedSessions(live, pins).length + flows.length;
      // The whole order for Move Up and Down, which a search shows only some of.
      lines.push(...pinnedSessions(live, pins, parsed)
        .map((agent): SmartLine => ({ ...placed, kind: "session", agent, pins: parsed ? undefined : pins })));
      lines.push(...flows.filter(workflowMatches(store, host, parsed))
        .map((summary): SmartLine => ({ ...placed, kind: "workflow", summary, pins: parsed ? undefined : flowPins })));
    }
  } else {
    const found = new Map<Agent, Placed>();
    for (const placed of folders) {
      const live = liveSessions(store, placed.host.id, placed.folder.folder.folder);
      // The pinned are in Pinned alone: each session is listed once (#587).
      const pins = store.sessionPinsIn(placed.host.id, placed.folder.folder.folder);
      // A failed workflow run's agent is its workflow's row under Needs You, not a session too (#989).
      const failed = row === "needsYou" ? failedRuns(placed.folder.approvals) : new Set<string>();
      const gathered = (query?: typeof parsed) => smartAgents(row, live, query, pins, on).filter((a) => !failed.has(a.id));
      count += gathered().length;
      if (open || parsed) for (const agent of gathered(parsed)) found.set(agent, placed);
    }
    // Unread keeps the session opened from it in its place, read now; none while searching.
    const kept = row === "unread" && !parsed ? keptInUnread.value : null;
    const keptAgent = kept ? store.agent(kept.host, kept.id) : undefined;
    keptPlace = keptAgent && keepsInUnread(keptAgent, store.sessionPinsIn(kept!.host, agentFolderPath(keptAgent)), on) ? folders.find(({ host, folder }) =>
      host.id === kept!.host && folderKey(folder.folder.folder) === agentFolderPath(keptAgent)) : undefined;
    // Each under the session that started it when this group lists that too (#835).
    const listed = withKept([...found.keys()].sort(byStart), keptPlace ? keptAgent : undefined);
    lines = treeRows(listed, (id) => startedByOf(store, id), (id) => folds.isSessionOpen(id))
      .map((tree): SmartLine => ({ ...(found.get(tree.agent) ?? keptPlace!), kind: "session", agent: tree.agent, tree }));
  }
  // What waits for an OK, each folder's, after the sessions (#773).
  const waiting = row !== "needsYou" ? [] : folders.map((placed) => ({ folder: placed, approvals: placed.folder.approvals }));
  const approvals = smartApprovals(waiting, query);
  if (row === "needsYou") count += query ? smartApprovals(waiting).length : approvals.length;
  if (parsed ? lines.length === 0 && approvals.length === 0 : count === 0 && !keptPlace) return null;
  const title = smartTitles[row];
  const updated = row === "needsYou" && downSince !== undefined ? updatedLine(downSince) : null;
  return (
    <details class={`smart ${row}`} role="group" aria-label={title} open={open}
      onToggle={(e) => {
        const now = (e.currentTarget as HTMLDetailsElement).open;
        if (now !== open) folds.setSmart(row, now);
      }}>
      <summary class="sidebar-head-label" data-fold={`smart.${row}`}
        aria-label={[title, count > 0 ? `${count}` : "none", updated].filter(Boolean).join(", ")}>
        {title}
        {updated && <span class="updated">{updated}</span>}
        {count > 0 && <span class={`count${row === "needsYou" ? " needs" : ""}`}>{count}</span>}
      </summary>
      {open && lines.map((line) => {
        const host = line.host.id;
        const folder = line.folder.folder.folder;
        const down = linkDown || !store.hostIsOnline(host);
        const place = folderLabel(line.host, line.folder, store.macHostID.value);
        return line.kind === "session" ? (
          <SidebarSession key={`${host}|${line.agent.id}`} store={store} host={host} folder={folder} agent={line.agent}
            chosen={r.host === host && r.session === line.agent.id} down={down} pinnedAt={line.pins} place={place} tree={line.tree} />
        ) : (
          <div class="nav-item" key={`${host}|${line.summary.workflow.workflowID}`}>
            <WorkflowRow store={store} host={host} summary={line.summary} disabled={down} place={place}
              chosen={r.host === host && r.workflow === line.summary.workflow.workflowID} pinnedAt={line.pins}
              onPick={() => go({ host, folder: folder, workflow: line.summary.workflow.workflowID })} />
          </div>
        );
      })}
      {open && approvals.map(({ folder: placed, approval }) => {
        const host = placed.host.id;
        const folder = placed.folder.folder.folder;
        const key = `${host}|${folder}|${approvalID(approval)}`;
        const place = folderLabel(placed.host, placed.folder, store.macHostID.value);
        const down = linkDown || !store.hostIsOnline(host);
        if (opensItsSubject(approval)) {
          const agentID = approval.agentID as string | undefined;
          return (
            <FailedWorkflowRow key={key} store={store} host={host} folder={folder} approval={approval} place={place} down={down}
              chosen={agentID ? r.host === host && r.session === agentID : r.host === host && r.workflow === approval.key} />
          );
        }
        return <ApprovalRow key={key} store={store} host={host} folder={folder} approval={approval} place={place} down={down}
          chosen={r.host === host && r.review === approvalID(approval) && r.folder !== undefined && folderKey(r.folder) === folderKey(folder)} />;
      })}
    </details>
  );
}

/**
 * One folder (#495): a group headed by its row, then its pinned pages, its live sessions newest
 * started first with their state the row's mark, its Workflows fold (#885), and one Archived row
 * opening a page. Its pinned sessions and workflows are in Pinned at the top. A search unfolds every folder
 * with something that matches, its archived matches inline, and hides the rest. It reads its own
 * folder's agents alone, so a change to an agent draws one fold again, and a folded one reads
 * nothing of its sessions (#170). `query` is the search's words, already trimmed.
 */
const FolderFold = memo(function FolderFold({ store, host, folder: summary, query, linkDown, alone: isAlone = false }: {
  store: Store; host: ControlHost; folder: FolderSummary; query: string; linkDown: boolean;
  /** In a tab holding this folder alone (#1089): its rows under a Sessions heading, always open. */
  alone?: boolean;
}) {
  const r = route.value;
  const folder = summary.folder.folder;
  const label = folderLabel(host, summary, store.macHostID.value);
  const searching = query !== "";
  const unfolded = searching || isAlone || folds.isOpen(host.id, folder);
  const down = linkDown || !store.hostIsOnline(host.id);
  // Every match on show, past the first few; a new search shows the few again.
  const showsAllMatches = useSignal(false);
  const configOpen = useSignal(false);
  useEffect(() => { showsAllMatches.value = false; }, [query]);
  const online = store.hostIsOnline(host.id);
  // A file dragged onto the row goes into the folder's drop box (#231). Before any early return:
  // it is a hook.
  const drop = useDropboxDrop(store, host.id, folder, down);
  // The list is held while the folder is open, and let go when it folds (#291).
  useEffect(() => {
    if (!unfolded || !online) return;
    store.holdWorkflows(host.id, folder);
    void store.loadArchived(host.id, folder);
    return () => {
      store.releaseWorkflows(host.id, folder);
      store.unloadArchived(host.id, folder);
    };
  }, [unfolded, online, host.id, folder]);

  const view = store.folderView(host.id, folder);
  // The matcher is made once per fold, not per row.
  const parsed = searching ? { ...parseQuery(query), said: store.saidLines.value } : undefined;
  const live = view.headings.flatMap((h) => h.agents);
  // Those a group at the top lists are there alone (#495, #587), out of the folder's list. A
  // group turned off (#846) lists nothing, so its sessions are here unless the next group has them.
  const on = smartGroupsOn.value;
  const pins = store.sessionPinsIn(host.id, folder);
  // The one Unread keeps while it is open is listed there, not here too (#689).
  const keptID = !parsed && keptInUnread.value?.host === host.id ? keptInUnread.value.id : undefined;
  const keptAgent = keptID ? live.find((a) => a.id === keptID) : undefined;
  const kept = keptAgent && keepsInUnread(keptAgent, pins, on) ? keptAgent.id : undefined;
  const sessions = !unfolded ? [] : folderSessions(live, pins, parsed, kept, on);
  const recentArchived = !parsed ? view.archived.slice(0, 3) : [];
  const archived = !unfolded || !parsed ? [] : view.archived.filter((a) => queryMatches(parsed, a));
  const allWorkflows = (unfolded ? store.folderWorkflows(host.id, folder) : [])
    .filter(workflowMatches(store, host.id, parsed))
    .sort((a, b) => a.workflow.name.localeCompare(b.workflow.name));
  // With Pinned off (#846), the pinned workflows are in the folder's list with the rest.
  const flowPins = on.has("pinned") ? store.workflowPinsIn(host.id, folder) : [];
  const workflows = allWorkflows.filter((w) => !w.isArchived && !flowPins.includes(w.workflow.workflowID));
  const folderWorkflows = workflows.filter((w) => w.scope !== "user");
  const userWorkflows = workflows.filter((w) => w.scope === "user");
  const archivedWorkflows = allWorkflows.filter((w) => w.isArchived);
  const workflowsOpen = searching || folds.isWorkflowsOpen(host.id, folder);
  // Under a Sessions row, as the workflows are under theirs (#2312), the only layout (#2381); not in a
  // tab of the folder alone, whose group is headed Sessions already. A search holds it open.
  const groupsSessions = !isAlone && sessions.length > 0;
  const sessionsOpen = searching || folds.isSessionsOpen(host.id, folder);
  const recentArchivedOpen = searching || folds.isRecentArchivedSessionsOpen(host.id, folder);
  const nameMatches = label.toLowerCase().includes(query.toLowerCase());
  if (searching && sessions.length === 0 && archived.length === 0 && workflows.length === 0
    && archivedWorkflows.length === 0 && !nameMatches) return null;

  const here = r.host === host.id && r.folder !== undefined && folderKey(r.folder) === folderKey(folder);
  const archiveCount = (summary.counts.archived ?? 0) + archivedWorkflows.length;
  const mcpServers = folderServers(store.mcpHealthOf(host.id), folder);
  const mcpTally = healthTally(mcpServers);
  const fold = (open: boolean) => folds.set(host.id, folder, open);
  const folderPinned = summary.folder.pinned === true;
  const folderMenu: MenuItem[] = [
    { label: "New Session", disabled: down, help: "Start a new session in this folder",
      run: () => go({ host: host.id, folder: folder, compose: true }) },
    // The folder alone, in a tab of its own (#1089), as the window opens it in a window of its own.
    { label: "Open in New Tab", help: "Open this folder alone in a new browser tab",
      run: () => void window.open(aloneURL(host.id, folder), "_blank", "noopener") },
    { label: "Put Files in Drop Box…", disabled: down, help: "Put files into this folder's .agents/dropbox/ (#231)",
      run: () => putFilesInDropbox(host.id, folder, label) },
    { label: "Agent Configuration…", disabled: down,
      run: () => { configOpen.value = true; } },
    ...showHiddenViewsItem(store, host.id, folder, down),
    // To the top of the sidebar, as the window's Pin.
    { label: folderPinned ? "Unpin" : "Pin", disabled: down,
      help: folderPinned ? "Let this folder take its place among the others" : "Keep this folder at the top of the sidebar",
      run: () => void store.setFolderPinned(host.id, folder, !folderPinned) },
    // Into Archived folders, asked first (#668), as the window's Archive.
    { label: "Archive…", disabled: down, help: "Put this folder away in Archived folders",
      run: () => {
        if (!confirm(`${archiveFolderTitle(label)}\n\n${archiveFolderMessage}`)) return;
        void store.archiveFolder(host.id, folder).then((summary) => {
          if (summary && here) go({});
        });
      } },
    // Its agents as a .tar.gz, and an export brought back on its machine (#1001), as the window's.
    ...(store.has(host.id, Capability.agentsExport1) ? [
      { label: "Export Agents…", disabled: down || !!store.exportImport.value, help: "Download this folder's agents as a .tar.gz",
        run: () => exportFromMenu(store, host.id, { folder: folder as NonNullable<AgentsExportRequest["folder"]> }) },
      { label: "Import Agents…", disabled: down || !!store.exportImport.value, help: "Bring back the agents of an export, archived, into this folder",
        run: () => importFromMenu(store, host.id, { folder, name: summary.name }) },
    ] : []),
  ];
  const row = (agent: Agent, tree?: TreeRow) => (
    <SidebarSession key={agent.id} store={store} host={host.id} folder={folder} agent={agent}
      chosen={r.host === host.id && r.session === agent.id} down={down} tree={tree} />
  );
  // Each under the session that started it, folded (#835).
  const sessionRows = treeRows(sessions, (id) => store.agent(host.id, id)?.startedByAgent, (id) => folds.isSessionOpen(id));
  const workflowRow = (summary: WorkflowSummary) => (
    <div class="nav-item" key={summary.workflow.workflowID}>
      <WorkflowRow store={store} host={host.id} summary={summary} disabled={down}
        chosen={here && r.workflow === summary.workflow.workflowID}
        onPick={() => go({ host: host.id, folder: folder, workflow: summary.workflow.workflowID })} />
    </div>
  );
  return (
    <div class={`folder-fold${down && !linkDown ? " greyed" : ""}`} role="group" aria-label={label}
      data-host={host.id} data-folder={folder}>
      {configOpen.value && <ProjectAgentConfigModal store={store} host={host.id} folder={folder} down={down}
        close={() => { configOpen.value = false; }} />}
      {isAlone ? (
        // The tab is the folder, so its name is the tab's title and not a heading (#1089).
        <p class={`sidebar-head-label alone-sessions${drop.targeted ? " drop-target" : ""}`} {...drop.props}>Sessions</p>
      ) : (
      <div class={`row folder${drop.targeted ? " drop-target" : ""}`} {...drop.props}>
        <button class="disclosure" aria-label={unfolded ? `Fold ${label}` : `Unfold ${label}`} aria-expanded={unfolded}
          tabIndex={-1} disabled={searching} onClick={() => fold(!unfolded)}>{unfolded ? "⌄" : "›"}</button>
        <button class="pick" aria-expanded={unfolded} data-fold="folder" title={folderPath(folder)}
          onClick={(e) => {
            // The row folds or unfolds, and nothing else (#375): a session starts from New Session
            // at the top. Not when the arrow keys land here (a click with no detail): moving
            // through the list folds nothing.
            if (e.detail > 0 && !searching) fold(!unfolded);
          }}
          onContextMenu={(e) => openContextMenu(e, folderMenu)} {...holdForMenu(() => folderMenu)}
          onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, folderMenu); }}>
          <span class="title">{label}</span>
          {/* A heading, as the groups' at the top (#587): who needs you is in Needs You, so no
              line under it and no dot; only a missing folder is said. */}
          {!summary.exists && <span class="subtitle">Folder is missing</span>}
        </button>
      </div>
      )}
      <DropNote note={drop.note} />
      {unfolded && (
        <div class="fold-body">
          {/* The folder's pinned pages first (#159), not while searching: the search is for sessions. */}
          {!searching && <PinnedPageRows store={store} host={host.id} folder={folder} down={down} chosen={here ? r.page : undefined} />}
          {/* Then its servers' list views, without a pin (#2032). */}
          {!searching && <ServerViewRows store={store} host={host.id} folder={folder} down={down} chosen={here ? r.page : undefined} />}
          {groupsSessions ? (
            <details class="sessions" open={sessionsOpen}
              onToggle={(e) => {
                const now = (e.currentTarget as HTMLDetailsElement).open;
                if (!searching && now !== sessionsOpen) folds.setSessions(host.id, folder, now);
              }}>
              <summary data-fold="sessions" aria-label={`Sessions, ${sessions.length}`}>
                Sessions<span class="count">{sessions.length}</span>
              </summary>
              {sessionsOpen && sessionRows.map((tree) => row(tree.agent, tree))}
            </details>
          ) : sessionRows.map((tree) => row(tree.agent, tree))}
          {recentArchived.length > 0 && (
            <details class="recent-archived-sessions" open={recentArchivedOpen}
              onToggle={(e) => {
                const now = (e.currentTarget as HTMLDetailsElement).open;
                if (!searching && now !== recentArchivedOpen) folds.setRecentArchivedSessions(host.id, folder, now);
              }}>
              <summary data-fold="recent-archived-sessions" aria-label={`Recently archived sessions, ${recentArchived.length}`}>
                Recently archived sessions<span class="count">{recentArchived.length}</span>
              </summary>
              {recentArchivedOpen && recentArchived.map((agent) => row(agent))}
            </details>
          )}
          {/* Its workflows after the sessions (#495), in a Workflows fold of their own, one level in,
              as a mailbox's sub-mailboxes in Mail (#885): folded until opened, kept per folder, its
              grey count on the right. A search holds it open. */}
          {workflows.length > 0 && (
            <details class="workflows" open={workflowsOpen}
              onToggle={(e) => {
                const now = (e.currentTarget as HTMLDetailsElement).open;
                if (!searching && now !== workflowsOpen) folds.setWorkflows(host.id, folder, now);
              }}>
              <summary data-fold="workflows" aria-label={`Workflows, ${workflows.length}`}>
                Workflows<span class="count">{workflows.length}</span>
              </summary>
              {workflowsOpen && <>
                {folderWorkflows.length > 0 && <>
                  <div class="workflow-group-heading">Folder workflows<span class="count">{folderWorkflows.length}</span></div>
                  {folderWorkflows.map(workflowRow)}
                </>}
                {userWorkflows.length > 0 && <>
                  <div class="workflow-group-heading">User workflows<span class="count">{userWorkflows.length}</span></div>
                  {userWorkflows.map(workflowRow)}
                </>}
              </>}
            </details>
          )}
          {searching ? <>
            {/* What matched in the archive, in the group while searching, so a match is one click away. */}
            {archivedWorkflows.map(workflowRow)}
            {archived.slice(0, showsAllMatches.value ? archived.length : matchesShown).map((agent) => row(agent))}
            {!showsAllMatches.value && archived.length > matchesShown && (
              <button class="link show-all" onClick={() => (showsAllMatches.value = true)}>Show all {archived.length}</button>
            )}
          </> : <>
          {/* Its connectors (#753), under every folder even with none yet (#1422): a page, red when one does not answer,
              with how many after the title, small and grey, none at zero (#1569). */}
          <div class="nav-item">
            <div class={`row page-row${here && r.mcp ? " chosen" : ""}`}>
              <button class="pick" aria-current={here && !!r.mcp} aria-label={`Connectors, ${mcpTally?.words ?? "none yet"}`}
                title={mcpTally?.words ?? "No connectors yet"} onClick={() => go({ host: host.id, folder: folder, mcp: true })}>
                <span class={`pin-mark${mcpTally?.failing ? " warns" : ""}`} aria-hidden="true">▤</span>
                <span class="title">Connectors{mcpServers.length > 0 && <span class="count">{mcpServers.length}</span>}</span>
              </button>
            </div>
          </div>
          {archiveCount > 0 && (
            // The archive, one row opening a page (#495): never a fold inside the group.
            <div class="nav-item">
              <div class={`row page-row${here && r.archive ? " chosen" : ""}`}>
                {/* Nothing at its end, which is only a session's (#587): the count is its tooltip's. */}
                <button class="pick" aria-current={here && !!r.archive} aria-label={`Archived, ${archiveCount}`}
                  title={`${archiveCount} archived`} onClick={() => go({ host: host.id, folder: folder, archive: true })}>
                  <span class="pin-mark" aria-hidden="true">▣</span>
                  <span class="title">Archived</span>
                </button>
              </div>
            </div>
          )}
          </>}
        </div>
      )}
    </div>
  );
});

/**
 * An archived folder, with when it was put away, Unarchive and Delete…, as the window's
 * ArchivedFolderRow (#343, #677), named as its live row was: `server:Folder` on a server.
 * Unarchived, it is a folder again and its new-session form opens.
 */
function ArchivedFolderRow({ store, host, folder: summary, down }: {
  store: Store; host: ControlHost; folder: FolderSummary; down: boolean;
}) {
  const folder = summary.folder.folder;
  const archivedAt = summary.folder.archivedAt;
  const label = folderLabel(host, summary, store.macHostID.value);
  const unarchive = async () => {
    if (await store.unarchiveFolder(host.id, folder)) go({ host: host.id, folder: folder, compose: true });
  };
  const remove = () => {
    if (confirm(`${deleteFolderTitle(label)}\n\n${deleteFolderMessage}`)) void store.deleteFolder(host.id, folder);
  };
  const menu: MenuItem[] = [
    { label: "Unarchive", disabled: down, run: () => void unarchive() },
    { label: "Delete…", disabled: down, run: remove },
  ];
  return (
    <div class="row archived-folder" title={folderPath(folder)}
      onContextMenu={(e) => openContextMenu(e, menu)} {...holdForMenu(() => menu)}>
      <span class="title">{label}</span>
      <button class="link" disabled={down} onClick={() => void unarchive()}
        onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, menu); }}>Unarchive</button>
      {archivedAt !== undefined && <span class="subtitle">Archived {namedRelative(fromWireDate(archivedAt))}</span>}
    </div>
  );
}

/** FolderArchiveWords.confirmTitle: "Archive “devbox:Agents”?". */
export function archiveFolderTitle(label: string): string {
  return `Archive \u201C${label}\u201D?`;
}

/** FolderArchiveWords.confirmMessage. */
export const archiveFolderMessage = "It moves to Archived folders with its sessions, and its workflows stop. "
  + "Unarchive returns it. Its folder and files are not touched.";

/** DeletionWords.folderConfirmTitle: "Delete “devbox:Agents”?". */
export function deleteFolderTitle(label: string): string {
  return `Delete \u201C${label}\u201D?`;
}

/** DeletionWords.folderConfirmMessage. */
export const deleteFolderMessage = "Every session in it is deleted, with its conversation and record, "
  + "and the folder leaves the list. Its folder and files are not touched. This cannot be undone.";

/**
 * One session's row in the sidebar, drawn again only when the agent, whether it is chosen, or its
 * host's state changes, or something is on its way to it: not when its neighbours change.
 */
export const SidebarSession = memo(function SidebarSession({ store, host, folder, agent, chosen, down, pinnedAt, place, tree }: {
  store: Store; host: string; folder: string; agent: Agent; chosen: boolean; down: boolean;
  /** Where it sits in its list's tree (#835): a parent with its count and fold, or a child one indent in. */
  tree?: TreeRow | undefined;
  /** Under Pinned: the whole pinned order, for its Move Up and Move Down (#180). */
  pinnedAt?: string[] | undefined;
  /** Under a group at the top, which gathers every folder's: its folder's name (#495). */
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
    // Beside this tab or in a window of its own (#826), as the Mac's Open in New Window.
    { label: "Open in New Tab", help: "Open this session in a new browser tab", run: () => openInNewTab(host, agent) },
    ...sessionActions(agent, store.sessionPinsIn(host, folder).includes(agent.id), startedBy(store, host, agent),
      store.has(host, Capability.mute1)).map(({ action, label: words, help }) => ({
      label: words, help, disabled: down || !!store.onItsWay.value[agent.id],
      run: () => runSessionAction(store, host, agent, action),
    })),
    // Its record and transcript as a .tar.gz (#1001), as the window's Export….
    ...(store.has(host, Capability.agentsExport1) ? [
      { label: "Export…", help: "Download this session as a .tar.gz", disabled: down || !!store.exportImport.value,
        run: () => exportFromMenu(store, host, { agentID: agent.id }) },
    ] : []),
    ...(pinnedAt ? [
      { label: "Move Up", disabled: down || pinnedAt[0] === agent.id, run: () => move(-1) },
      { label: "Move Down", disabled: down || pinnedAt[pinnedAt.length - 1] === agent.id, run: () => move(1) },
    ] : []),
  ];
  // Into its folder's drop box, never its worktree (#231).
  const drop = useDropboxDrop(store, host, folder, down);
  const parent = tree !== undefined && tree.children > 0;
  // A folded parent's mark is the most urgent of it and the sessions it started (#835).
  const markAgent = parent && !tree.isUnfolded ? markAgentOf(agent, startedBy(store, host, agent)) : undefined;
  const treeClass = tree?.isChild ? " child" : parent ? " parent" : "";
  return (
    <>
    <div class={`nav-item${treeClass}${drop.targeted ? " drop-target" : ""}`} onContextMenu={(e) => openContextMenu(e, menu())}
      onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, menu()); }} {...holdForMenu(menu)} {...drop.props}
      // A double-click edits its title in the row, as the window's does (#1518).
      onDblClick={(e) => {
        if (agent.state === "archived" || (e.target as HTMLElement).closest(".fold-count, .renaming")) return;
        e.preventDefault();
        runSessionAction(store, host, agent, "rename");
      }}>
      {/* No wait lines: in the sidebar a session's row is its title and one line (#587). */}
      {store.renaming.value?.id === agent.id && !store.renaming.value.inChat
        ? <div class="row session renaming"><RenameInput store={store} host={host} agent={agent} /></div>
        : <SessionRow agent={agent} chosen={chosen} onPick={() => { if (chosen) store.toEndAsks.value++; go({ host, folder: folder, session: agent.id }); }} going={going}
        extras={rowExtras(store, host, agent)}
        inSidebar place={place} markAgent={markAgent} />}
      {parent && (
        <button class="fold-count" aria-expanded={tree.isUnfolded}
          aria-label={tree.isUnfolded ? `Hide ${tree.children} started sessions` : `Show ${tree.children} started sessions`}
          title={tree.isUnfolded ? "Hide the sessions it started" : `Show the ${tree.children} sessions it started`}
          onClick={() => folds.setSession(agent.id, !tree.isUnfolded)}>
          {tree.children}<span class={`chevron${tree.isUnfolded ? " open" : ""}`} aria-hidden="true">›</span>
        </button>
      )}
    </div>
    <DropNote note={drop.note} />
    </>
  );
});

/** Where files dropped on the row above went (#934), for a moment; read out as it comes. */
function DropNote({ note }: { note: string | null }) {
  return <div class="drop-note" role="status">{note}</div>;
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
    ".new-session-top .pick, .activity .row, details.smart > summary, details.sessions > summary, details.workflows > summary, .folder-fold > .row.folder .pick, .nav-item .row.pin .pick, .nav-item .row.session, .nav-item .row.workflow .pick, .nav-item .row.page-row .pick, details.archived > summary",
  )].filter((el) => el.offsetParent !== null);
}

/**
 * ↑ and ↓ through the list, opening what they land on (a fold's summary and an approval are landed
 * on and not opened); → unfolds and ← folds, or steps out to the folder; Home and End.
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
    // A fold's summary, and what waits for an OK, whose sheet Enter opens (#773), are only landed on.
    if (el.tagName !== "SUMMARY" && !el.classList.contains("approval")) el.click();
  };
  const fold = current.closest<HTMLElement>(".folder-fold");
  const isFolder = current.matches(".pick[data-fold=folder]");
  switch (e.key) {
    case "ArrowDown": land(rows[here + 1]); break;
    case "ArrowUp": land(rows[here - 1]); break;
    case "Home": land(rows[0]); break;
    case "End": land(rows[rows.length - 1]); break;
    case "ArrowRight":
      if (isFolder && fold && current.getAttribute("aria-expanded") !== "true") {
        e.preventDefault();
        folds.set(fold.dataset.host!, fold.dataset.folder!, true);
      } else if (current.tagName === "SUMMARY" && !(current.parentElement as HTMLDetailsElement).open) {
        e.preventDefault();
        current.click();
      }
      break;
    case "ArrowLeft":
      if (isFolder && fold && current.getAttribute("aria-expanded") === "true") {
        e.preventDefault();
        folds.set(fold.dataset.host!, fold.dataset.folder!, false);
      } else if (current.tagName === "SUMMARY" && (current.parentElement as HTMLDetailsElement).open) {
        e.preventDefault();
        current.click();
      } else if (fold && !isFolder) {
        e.preventDefault();
        fold.querySelector<HTMLElement>(".pick[data-fold=folder]")?.focus();
      }
      break;
  }
}

/** The groups a tab holding one folder draws (#1089): Working and Unread are its sessions, in its list. */
const aloneRows = new Set<SmartRow>(["pinned", "needsYou"]);

/**
 * "✋ N elsewhere" (#1089): sessions in other folders need the person. A click shows every folder
 * again, at the first of them.
 */
function Elsewhere({ store, folders }: { store: Store; folders: Placed[] }) {
  const on = smartGroupsOn.value;
  let count = 0;
  let first: { host: string; folder: string; id: string } | undefined;
  for (const { host, folder } of folders) {
    const path = folder.folder.folder;
    const failed = failedRuns(folder.approvals);
    const asking = smartAgents("needsYou", liveSessions(store, host.id, path), undefined, store.sessionPinsIn(host.id, path), on)
      .filter((a) => !failed.has(a.id));
    count += asking.length;
    if (!first && asking[0]) first = { host: host.id, folder: path, id: asking[0].id };
  }
  count += smartApprovals(folders.map((placed) => ({ folder: placed, approvals: placed.folder.approvals }))).length;
  if (count === 0) return null;
  return (
    <button class="link elsewhere" title="Sessions in other folders need you"
      onClick={() => {
        showAll();
        if (first) go({ host: first.host, folder: first.folder, session: first.id });
      }}>✋ {count} elsewhere</button>
  );
}

/**
 * Undo after Archive (ArchiveUndoStrip, #1534): "Archived “Fix the parser”" with Undo for a few
 * seconds; ⌘Z (Ctrl+Z) does the same while it shows, outside a text field. A screen reader reads
 * the line and Undo when it comes, and the seconds wait while the pointer or the focus is on it (#1676).
 */
function ArchiveUndoStrip({ store }: { store: Store }) {
  const undo = store.archiveUndo.value;
  const hovering = useSignal(false);
  const focused = useSignal(false);
  const held = hovering.value || focused.value;
  // A strip that goes under the pointer gets no mouseleave: each Archive starts unheld.
  useEffect(() => { hovering.value = false; focused.value = false; }, [undo?.key]);
  useEffect(() => {
    if (!undo || held) return;
    const timer = setTimeout(() => {
      if (store.archiveUndo.value?.key === undo.key) store.archiveUndo.value = null;
    }, undoMillis);
    return () => clearTimeout(timer);
  }, [undo?.key, held]);
  useEffect(() => {
    if (!undo) return;
    const press = (e: KeyboardEvent) => {
      if (e.key.toLowerCase() !== "z" || !(e.metaKey || e.ctrlKey) || e.shiftKey || e.altKey) return;
      const target = e.target as HTMLElement | null;
      if (target?.closest("input, textarea, [contenteditable=true]")) return;
      e.preventDefault();
      void store.undoArchive();
    };
    document.addEventListener("keydown", press);
    return () => document.removeEventListener("keydown", press);
  }, [undo?.key]);
  if (!undo) return null;
  return (
    <p class="foot-line archive-undo" role="status" aria-live="polite" aria-atomic="true"
      onMouseEnter={() => { hovering.value = true; }} onMouseLeave={() => { hovering.value = false; }}
      onFocusIn={() => { focused.value = true; }} onFocusOut={() => { focused.value = false; }}>
      <span>{undo.line}</span>
      <button type="button" class="link" onClick={() => void store.undoArchive()}>{undoLabel}</button>
    </p>
  );
}
