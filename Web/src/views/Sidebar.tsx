// The page's one sidebar (#151), as the window's (#145, FolderListView.swift) and the Remote's
// (RemoteSidebar.swift), and below 760 the root list, as the iPhone Remote's (#226, #235).
// Things-style since #495 (#499): New Session at the top, in the folder last started in, and Agents'
// filters, a machine and a state (#2141); then what wants the person across every folder — Pinned, Needs You, Working, Unread — each drawn
// only with something in it (#507), Needs You with what waits for an OK after its sessions (#773); then a group per folder, its sessions newest started first
// with their state the row's mark, its Workflows fold (#885), and one Archived row opening a page; then the
// archived folders, Live Now (an admin's) and Projects (#2141); and at the foot what the hosts and
// this browser are doing. The Activity pages are in Machines and Reports since #2141. Never more than three
// levels deep: a folder's Workflows fold (#885) is the third. No host headings: a server's folder reads `host:Folder`. A folder's row only
// folds (#375).
//
// One list for the keys: ↑ and ↓ move through every row shown, opening what they land on, as the
// window's selection does; → unfolds a folder or group and ← folds it, or steps out to its folder
// from a row under it. The menu key, Shift-F10 or a right click opens a row's menu.
import { healthTally, folderServers } from "../model/hostedMCP";
import { signal, useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { ComponentChildren } from "preact";
import { byBack, laterWords } from "../model/later";
import { nonePage } from "./SummaryPage";
import { FolderSettingsModal, ProjectSettingsModal } from "./ProjectSettings";
import { projectSettingsWords } from "../model/projectSettings";
import { actDoing, type Store } from "../model/store";
import { byStart, folderKey, folderPath as agentFolderPath, showsUnread } from "../model/groups";
import { folds } from "../model/folds";
import { smartGroupsOn } from "../model/smartGroups";
import { macHostNoticeDetail, macHostNoticeTitle } from "../model/macHostNotice";
import { hostAnswers } from "../model/capabilities";
import { Capability } from "../protocol/capabilities.generated";
import { parseQuery, queryMatches, type LabelQuery } from "../model/labels";
import { searchPrompt, sidebarSearch } from "../model/sessionSearch";
import { folderLine, groupLabel, keeper, keepsInUnread, machineMark, machineState, newSessionFolder, pinnedSessions, pinnedWorkflows,
  connectorsPlace, folderSessions, projectGroups, rememberedFolder, rememberFolder, sharedProjects, smartAgents, smartApprovals, smartPulls,
  smartSuggestions, smartRows, smartTitles, withKept, groupsByIssue, issueGroups, type FolderKey, type ProjectGroup, type SmartRow } from "../model/sidebar";
import { endedLine } from "../model/connectorSetup";
import { lastUpdateSpoken, pageReadAt } from "../model/lastUpdate";
import { LastUpdate } from "./LastUpdate";
import { namedRelative, workflowSummary } from "../model/workflows";
import { fromWireDate } from "../protocol/dates";
import type { Agent, AgentsExportRequest, ControlMachine, FolderSummary, Request as PersonRequest, WorkflowSummary } from "../protocol/generated";
import { alone, aloneURL, go, route, showAll, type ArchiveRoute } from "../route";
import { sessionCount, sessionsWords, workflowCount, workflowsWords } from "../model/archivedPage";
import { onThisMac } from "../place";
import { browserName, type Session } from "../session";
import { keptByState, machineFilter, setMachineFilter, setStateFilter, stateFilter, stateFilterTitle, stateFilters,
  type StateFilter } from "../model/agentFilters";
import { adminOf } from "../model/console";
import { holdForMenu, isMenuKey, openContextMenu, type MenuItem } from "./ContextMenu";
import { CloningRows, EmptyFolders, NewFolderMenu } from "./NewFolder";
import { putFilesInDropbox, useDropboxDrop } from "./DropboxDialog";
import { exportFromMenu, importFromMenu } from "../model/exports";
import { rowExtras, SessionRow } from "./SessionRow";
import { prefetchOnHover } from "./hoverPrefetch";
import { canMoveOn, openInNewTab, RenameInput, runSessionAction, sessionActions, startedBy } from "./SessionMenu";
import { markAgentOf, treeRows, type TreeRow } from "../model/tree";
import { WorkflowRow } from "./WorkflowRow";
import { footLine, offersStart } from "./OfflineStrip";
import { PinnedPageRows, ServerViewRows, showHiddenViewsItem } from "./Pins";
import { RequestRow } from "./RequestRow";
import { ApprovalRow, FailedWorkflowRow } from "./Approval";
import { ReviewPullRow } from "./ReviewPull";
import { CheckSuggestionRow } from "./CheckSuggestion";
import { JoinRequests } from "./JoinRequest";
import { LinkRequests } from "./ChannelLinks";
import { SignInRequests } from "./SignInRequests";
import { LockJoins } from "./LockJoins";
import { approvalID, failedRuns, opensItsSubject } from "../model/approvals";
import { memo } from "../render/memo";
import { ask } from "./MessageKinds";
import { laterRequestOf, useListKeys } from "./ListKeys";
import { laterTime, listKeyGlyph } from "../model/listKeys";
import { Glyph, Icon, type IconName } from "./Icon";


/** Folder Settings asked for another folder of the project, from Project Settings' Folders (#3280). */
const otherFolderSettings = signal<{ host: string; folder: string } | null>(null);
/** The docs site: the guides and the statuses reference (#1327), as the window's Help ▸ Agents Help. */
const helpSite = "https://docs.agentloops.dev/";

/** The most archived matches a fold shows before Show all, as the window's (#176). */
const matchesShown = 10;

/** How long the typing pauses before the folds filter and the hosts are asked (#176). */
export const searchPause = 150;

/** A folder's name in the sidebar: `host:Folder` on a server, the name alone on this Mac (`macID`, #1501). */
export function folderLabel(host: ControlMachine | undefined, folder: FolderSummary, macID = "mac"): string {
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
export function orderedFolders(hosts: ControlMachine[], folders: Record<string, FolderSummary[]>, macID = "mac"):
  { host: ControlMachine; folder: FolderSummary }[] {
  const ordered = [...hosts.filter((h) => h.id === macID), ...hosts.filter((h) => h.id !== macID)];
  const byHost = ordered.flatMap((host) => (folders[host.id] ?? [])
    .filter((folder) => folder.folder.archivedAt === undefined)
    .sort(byAdded)
    .map((folder) => ({ host, folder })));
  return [...byHost.filter((r) => r.folder.folder.pinned === true),
          ...byHost.filter((r) => r.folder.folder.pinned !== true)];
}

/** Every host's archived folders, the latest archived first (#2153), as the window's Archived folders (#343). */
export function archivedFolders(hosts: ControlMachine[], folders: Record<string, FolderSummary[]>):
  { host: ControlMachine; folder: FolderSummary }[] {
  return hosts.flatMap((host) => (folders[host.id] ?? [])
    .filter((folder) => folder.folder.archivedAt !== undefined)
    .map((folder) => ({ host, folder })))
    .sort((a, b) => (b.folder.folder.archivedAt ?? b.folder.lastActivityAt) - (a.folder.folder.archivedAt ?? a.folder.lastActivityAt));
}

/** The names of the projects the sidebar groups (#3278), read from the control plane, by id. */
const projectNames = signal<Record<string, string>>({});

/** A project's name when the sidebar groups several folders under it (#3278), else undefined. */
export function projectNameOf(project: string | undefined): string | undefined {
  return project === undefined ? undefined : projectNames.value[project];
}

function placeKey(host: string, folder: string): string {
  return `${host}|${folderKey(folder)}`;
}

/** Each folder's group name (#3278): its own label alone, or its project's name. */
function groupLabels(groups: readonly ProjectGroup<Placed>[], macID: string): Map<string, string> {
  const labels = new Map<string, string>();
  for (const group of groups) {
    const { host, folder } = group.main;
    const name = groupLabel(group, folderLabel(host, folder, macID),
      folder.project === undefined ? undefined : projectNames.value[folder.project], folder.name);
    for (const placed of [group.main, ...group.others]) labels.set(placeKey(placed.host.id, placed.folder.folder.folder), name);
  }
  return labels;
}

/** The name a smart group's row says after its title: its folder's group name. */
function placeOf(places: ReadonlyMap<string, string>, host: ControlMachine, folder: FolderSummary, macID: string): string {
  return places.get(placeKey(host.id, folder.folder.folder)) ?? folderLabel(host, folder, macID);
}

export function Sidebar({ session, store, linkDown }: { session: Session; store: Store; linkDown: boolean }) {
  // The model's, so a label's chip can set it (#3898).
  const search = sidebarSearch;
  // What the folds filter by: the field's words once typing pauses, so a keystroke costs the
  // field and not a pass over every folder (#176, #193).
  const searched = useSignal("");
  const r = route.value;
  // j and k, e, l and r, while no field has the keys (#4796).
  useListKeys(store);
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
    keptInUnread.value = agent && showsUnread(agent) ? { host: r.host!, id: agent.id, hadFile: agent.fileToSee != null } : null;
  }, [r.host, r.session]);
  // What is open, from anywhere (a link, Back), unfolds its folder so its row is there to light,
  // unless an open group at the top already shows it.
  useEffect(() => {
    if (!r.host || !r.folder || !(r.session || r.workflow || r.page || r.archive || r.mcp)) return;
    const agent = r.session ? store.agent(r.host, r.session) : undefined;
    if (agent && inOpenSmartRow(store, r.host, agent)) return;
    if (r.workflow && smartGroupsOn.peek().has("pinned") && folds.isSmartOpen("pinned") && store.workflowPinsIn(r.host, r.folder).includes(r.workflow)) return;
    // A folder of a project is drawn in its project's group (#3278): that group unfolds.
    const at = placeKey(r.host, r.folder);
    const owner = projectGroups(orderedFolders(store.hosts.peek(), store.folders.peek(), store.macHostID.peek()), store.macHostID.peek())
      .find((g) => [g.main, ...g.others].some((p) => placeKey(p.host.id, p.folder.folder.folder) === at))?.main;
    folds.set(owner?.host.id ?? r.host, owner?.folder.folder.folder ?? r.folder, true);
  }, [r.host, r.folder, r.session, r.workflow, r.page, r.archive, r.mcp]);
  // The next New Session at the top starts here too (#495).
  useEffect(() => {
    if (r.host && r.folder && r.compose) rememberFolder(storage, { host: r.host, folder: r.folder });
  }, [r.host, r.folder, r.compose]);
  // A tab holding one folder alone (#1089): its sidebar is that folder's only.
  const held = alone.value;
  const every = orderedFolders(store.hosts.value, store.folders.value, store.macHostID.value);
  // Agents' filters (#2141): one machine's folders, and only the folders with a session in the state asked for.
  const machine = held ? null : machineFilter.value;
  const state = held ? "any" : stateFilter.value;
  const folders = held ? every.filter(({ host, folder }) => host.id === held.host
    && folderKey(folder.folder.folder) === folderKey(held.folder))
    : every.filter(({ host, folder }) => (machine === null || host.id === machine)
      && (state === "any" || liveSessions(store, host.id, folder.folder.folder).length > 0));
  const archived = held ? [] : archivedFolders(store.hosts.value, store.folders.value);
  // One group per project (#3278): a project's folders on every machine together.
  const groups = projectGroups(folders, store.macHostID.value);
  const places = groupLabels(groups, store.macHostID.value);
  const shared = sharedProjects(groups).join("\n");
  useEffect(() => {
    if (!shared) return;
    void store.link.call("projects/list", {}).then((list) => {
      projectNames.value = Object.fromEntries(list.projects.map((p) => [p.id, p.name]));
    }, () => { /* A failed read keeps the names it had; the main folder's name stands in. */ });
  }, [shared]);
  // The connections that ended (#3407): the host tells no client, so they are read on opening and every five minutes,
  // with the stored set-up of each project's Connectors folder on a host where one ended.
  const connectorPlaces = groups.map((g) => connectorsPlace(g, store.macHostID.value, (h) => store.hostIsOnline(h)))
    .map((p) => ({ host: p.host.id, folder: p.folder.folder.folder }));
  const connectorPlacesKey = connectorPlaces.map((p) => placeKey(p.host, p.folder)).join("\n");
  useEffect(() => {
    const read = () => void store.refreshEndedConnections(connectorPlaces);
    read();
    const every = window.setInterval(read, 5 * 60 * 1000);
    return () => window.clearInterval(every);
  }, [connectorPlacesKey]);
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
        <input class="search" type="search" placeholder={searchPrompt} aria-label="Search sessions and workflows"
          value={search.value} onInput={(e) => (search.value = (e.currentTarget as HTMLInputElement).value)} />
        {/* New folder, which the window has in its File menu (#115): the page has no menu bar. */}
        <NewFolderMenu store={store} newSession={newSessionStart(store, folders, linkDown)} />
      </header>
      {!held && <AgentFilters store={store} />}
      <div class="scroll" onKeyDown={(e) => moveWithKeys(e)}>
        {folders.length > 0 && <NewSessionTopRow store={store} folders={folders} linkDown={linkDown} />}
        {/* The daily summary's page (#3721), above the smart groups, while the daily summary is on. */}
        {!held && <SummaryRow store={store} />}
        {/* A machine asking to join (#994): at the top, whatever groups are on, and with no folder yet. */}
        {!held && <JoinRequests store={store} down={linkDown} />}
        {/* A channel identity asking to act as this person (#1762), beside the machines. */}
        {!held && <LinkRequests store={store} down={linkDown} />}
        {/* A new client that signed in with GitHub as this person (#995), beside them. */}
        {!held && <SignInRequests store={store} down={linkDown} />}
        {/* This device in its person's machine lock, and the devices that ask to join it (#3490). */}
        {!held && <LockJoins store={store} down={linkDown} />}
        {/* Pinned, Needs You, Working, Unread: a group each across every folder and host (#495, #773),
            each that is on in this browser's Settings (#846). */}
        {folders.length > 0 && smartRows.filter((row) => smartGroupsOn.value.has(row) && (!held || aloneRows.has(row))).map((row) => (
          <SmartFold key={row} row={row} store={store} folders={folders} places={places} query={query} linkDown={linkDown}
            readSince={pageReadAt(session.state.value, store.copyAt.value)} />
        ))}
        {/* One group per project (#495, #3278), its name the group's heading, its sessions the rows. A
            project with one folder is that folder's group, as before. */}
        <section class="folder-list" aria-label="Folders">
          {groups.map(({ main: { host, folder }, others }) => (
            <FolderFold key={`${host.id}|${folder.folder.folder}`} store={store} host={host} folder={folder}
              query={query} linkDown={linkDown} alone={!!held} others={others}
              groupName={others.length > 0 ? places.get(placeKey(host.id, folder.folder.folder)) : undefined} />
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
        {/* Every person's running agents for an admin, and every project (#2141): pages in the chat's place. */}
        {!held && <section class="agents-pages" aria-label="More">
          {adminOf(store) === true && <AgentsPageRow id="live" title="Live Now" icon="radio" />}
          <AgentsPageRow id="projects" title="Projects" icon="layout-grid" />
        </section>}
      </div>
      {/* What the hosts and this browser are doing, pinned at the foot: status lines rather than
          somewhere to go. Each is absent when there is nothing to say. */}
      <footer class="sidebar-foot">
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
            <Icon name="plug" /> {footLine(host)}
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
            <Icon name="triangle-alert" /> {store.isMac(host.id) ? note : `${host.name}: ${note}`}
          </p>
        )))}
        <div class="identity">
          <span>{browserName()} {onThisMac() ? "on this Mac" : "on the web"}</span>
          {/* The docs site (#1327), as the window's Help ▸ Agents Help. */}
          <a class="link" href={helpSite} target="_blank" rel="noopener">Help</a>
          {/* Forget This Browser is in the person's menu, in the top bar (#2142). */}
        </div>
      </footer>
    </nav>
  );
}

/** Agents' filters (#2141): one machine, and a state. A machine filter only with more than one machine. */
function AgentFilters({ store }: { store: Store }) {
  const hosts = store.hosts.value;
  const machine = machineFilter.value;
  return (
    <div class="agent-filters" role="group" aria-label="Filters">
      {(hosts.length > 1 || machine !== null) && (
        <select aria-label="Machine" value={machine ?? ""} onChange={(e) => setMachineFilter((e.currentTarget as HTMLSelectElement).value || null)}>
          <option value="">Every machine</option>
          {hosts.map((h) => <option key={h.id} value={h.id}>{h.name}</option>)}
        </select>
      )}
      <select aria-label="State" value={stateFilter.value} onChange={(e) => setStateFilter((e.currentTarget as HTMLSelectElement).value as StateFilter)}>
        {stateFilters.map((f) => <option key={f} value={f}>{stateFilterTitle[f]}</option>)}
      </select>
    </div>
  );
}

/** The Summary row (#3721), as the Mac's and the Remote's SummaryRowLabel: the newest page's title
 *  under it and a dot while that page is unread. Only while the daily summary is on. */
function SummaryRow({ store }: { store: Store }) {
  const settings = store.dailySummary.value;
  if (!settings || settings.mode === "off") return null;
  const newest = store.summaryPages.value[0];
  const chosen = route.value.nav === "agents" && route.value.section === "summary";
  return (
    <button class={`row activity-row summary-row${chosen ? " chosen" : ""}${newest?.unread ? " unread" : ""}`}
      aria-current={chosen} title="Your daily summary: what landed, what failed and what waits on you"
      onClick={() => go({ nav: "agents", section: "summary" })}>
      <Icon name="sun" class="activity-icon" />
      <span class="title">Summary{newest?.unread && <span class="dot" aria-label="Unread" />}</span>
      <span class="small quiet line">{newest?.title ?? nonePage}</span>
    </button>
  );
}

/** A row at the sidebar's foot that opens one of Agents' pages in the chat's place. */
function AgentsPageRow({ id, title, icon }: { id: string; title: string; icon: IconName }) {
  const chosen = route.value.nav === "agents" && route.value.section === id;
  return (
    <button class={`row activity-row${chosen ? " chosen" : ""}`} aria-current={chosen} onClick={() => go({ nav: "agents", section: id })}>
      <Icon name={icon} class="activity-icon" />
      <span class="title">{title}</span>
    </button>
  );
}

// Through window, so a test without a page reads nothing (Node warns on a bare localStorage).
const storage = globalThis.window?.localStorage;

/** The session opened while it was unread, which Unread keeps until another is opened (#495), or
 *  For Review when it had a file to see (`hadFile`, #3194). */
const keptInUnread = signal<{ host: string; id: string; hadFile: boolean } | null>(null);

type Placed = { host: ControlMachine; folder: FolderSummary };

/** One folder's live sessions, every group's, as held. */
/** Who started a session, on whichever host holds it: a smart group gathers every host's (#835). */
function startedByOf(store: Store, id: string): string | undefined {
  for (const agents of Object.values(store.agents.value)) {
    const found = agents?.find((a) => a.id === id);
    if (found) return found.startedByAgent;
  }
  return undefined;
}

/** A folder's live sessions as its group lists them (#3278): those no smart group lists, newest started first. */
function listedSessions(store: Store, host: string, folder: string, parsed: LabelQuery | undefined,
  on: ReadonlySet<SmartRow>): Agent[] {
  const live = liveSessions(store, host, folder);
  const pins = store.sessionPinsIn(host, folder);
  const keptID = !parsed && keptInUnread.value?.host === host ? keptInUnread.value.id : undefined;
  const keptAgent = keptID ? live.find((a) => a.id === keptID) : undefined;
  const kept = keptAgent && keepsInUnread(keptAgent, pins, on, keeper(keptInUnread.value?.hadFile ?? false, on)) ? keptAgent.id : undefined;
  return folderSessions(live, pins, parsed, kept, on);
}

function liveSessions(store: Store, host: string, folder: string): Agent[] {
  const state = alone.value ? "any" : stateFilter.value;
  return store.folderView(host, folder).headings.flatMap((h) => h.agents).filter((a) => keptByState(a, state));
}

/** Whether a session is in sight under an open group at the top, so its folder need not unfold. */
function inOpenSmartRow(store: Store, host: string, agent: Agent): boolean {
  const on = smartGroupsOn.peek();
  const pins = store.sessionPinsIn(host, agentFolderPath(agent));
  if (on.has("pinned") && folds.isSmartOpen("pinned") && pins.includes(agent.id)) return true;
  const kept = keptInUnread.peek();
  const keptBy = keeper(kept?.hadFile ?? false, on);
  if (on.has(keptBy) && folds.isSmartOpen(keptBy) && kept?.host === host && kept.id === agent.id) return true;
  return (["needsYou", "forReview", "working", "unread"] as const).some((row) => folds.isSmartOpen(row) && smartAgents(row, [agent], undefined, pins, on).length > 0);
}

/** A search narrows workflows by name and what they are; one asking for a label or an issue leaves them out. */
export function workflowMatches(store: Store, host: string, query: LabelQuery | undefined): (w: WorkflowSummary) => boolean {
  if (!query) return () => true;
  const runtimeName = (id: string) => (store.runtimes.value[host] ?? []).find((s) => s.runtime.id === id)?.runtime.name;
  const text = query.text.toLowerCase();
  return (w) => query.label === null && query.issue === null && (!text
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
          <Icon name="square-pen" class="pin-mark" />
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
function SmartFold({ row, store, folders, places, query, linkDown, readSince }: {
  row: SmartRow; store: Store; folders: Placed[]; query: string; linkDown: boolean;
  /** Each folder's group name (#3278), which a row says after its title. */
  places: ReadonlyMap<string, string>;
  /** When the link was lost: Needs You says its count was last true then (#1163). */
  /** When what the page shows was read, while it is not live (#5141). */
  readSince?: number | undefined;
}) {
  const r = route.value;
  const parsed = query ? { ...parseQuery(query), said: store.saidLines.value, onIssue: store.issueSessions.value, issueHeadings: store.issueHeadings.value } : undefined;
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
      // A failed workflow run's agent is its workflow's row under Needs You, not a session too (#989);
      // an asker, its requests' rows (#3864), in Needs You or in Later (#4236).
      const failed = row === "needsYou" ? failedRuns(placed.folder.approvals) : new Set<string>();
      if (row === "needsYou") {
        for (const request of store.openPersonRequestsIn(placed.host.id, placed.folder.folder.folder)) failed.add(request.askedBy as string);
      }
      const gathered = (query?: typeof parsed) => smartAgents(row, live, query, pins, on).filter((a) => !failed.has(a.id));
      count += gathered().length;
      if (open || parsed) for (const agent of gathered(parsed)) found.set(agent, placed);
    }
    // Unread keeps the session opened from it in its place, read now, or For Review (#3194); none while searching.
    const kept = !parsed && row === keeper(keptInUnread.value?.hadFile ?? false, on) ? keptInUnread.value : null;
    const keptAgent = kept ? store.agent(kept.host, kept.id) : undefined;
    keptPlace = keptAgent && keepsInUnread(keptAgent, store.sessionPinsIn(kept!.host, agentFolderPath(keptAgent)), on, row) ? folders.find(({ host, folder }) =>
      host.id === kept!.host && folderKey(folder.folder.folder) === agentFolderPath(keptAgent)) : undefined;
    // Each under the session that started it when this group lists that too (#835).
    const listed = withKept([...found.keys()].sort(byStart), keptPlace ? keptAgent : undefined);
    lines = treeRows(listed, (id) => startedByOf(store, id), (id) => folds.isSessionOpen(id))
      .map((tree): SmartLine => ({ ...(found.get(tree.agent) ?? keptPlace!), kind: "session", agent: tree.agent, tree }));
  }
  // Each request to the person, each folder's, before the sessions (#3864). A search matches the title.
  // A terminal's agents-secret (#4179) is in no folder: each machine's are listed with the rest.
  const hostsHere = [...new Map(folders.map((placed) => [placed.host.id, placed.host])).values()];
  const requests: { host: Placed["host"]; folder?: Placed; request: PersonRequest }[] = row !== "needsYou" ? [] : [
    ...hostsHere.flatMap((host) => store.terminalRequests(host.id).map((request) => ({ host, request }))),
    ...folders.flatMap((placed) => store.personRequestsIn(placed.host.id, placed.folder.folder.folder)
      .map((request) => ({ host: placed.host, folder: placed, request }))),
  ].sort((a, b) => a.request.askedAt - b.request.askedAt);
  const asked = parsed ? requests.filter(({ request }) => request.title.toLowerCase().includes(query.toLowerCase())) : requests;
  count += requests.length;
  // The deferred ones (#4236), in the folded Later group at the end, the soonest back first, in no count.
  const deferred: typeof requests = row !== "needsYou" ? [] : [
    ...hostsHere.flatMap((host) => store.laterTerminalRequests(host.id).map((request) => ({ host, request }))),
    ...folders.flatMap((placed) => store.laterRequestsIn(placed.host.id, placed.folder.folder.folder)
      .map((request) => ({ host: placed.host, folder: placed, request }))),
  ].sort((a, b) => byBack(a.request, b.request));
  const later = parsed ? deferred.filter(({ request }) => request.title.toLowerCase().includes(query.toLowerCase())) : deferred;
  // What waits for an OK, each folder's, after the sessions (#773).
  const waiting = row !== "needsYou" ? [] : folders.map((placed) => ({ folder: placed, approvals: placed.folder.approvals }));
  const approvals = smartApprovals(waiting, query);
  if (row === "needsYou") count += query ? smartApprovals(waiting).length : approvals.length;
  // The pull requests waiting for an approval, each folder's, after For Review's sessions (#3330).
  const reviewing = row !== "forReview" ? [] : folders.map((placed) => ({ folder: placed,
    pulls: store.reviewPullsIn(placed.host.id, placed.folder.folder.folder) }));
  const pulls = smartPulls(reviewing, query);
  if (row === "forReview") count += query ? smartPulls(reviewing).length : pulls.length;
  // The daily checks' suggestions, each folder's, after them (#3331).
  const checked = row !== "forReview" ? [] : folders.map((placed) => ({ folder: placed,
    suggestions: store.checkSuggestionsIn(placed.host.id, placed.folder.folder.folder) }));
  const suggestions = smartSuggestions(checked, query);
  if (row === "forReview") count += query ? smartSuggestions(checked).length : suggestions.length;
  // Later alone keeps Needs You drawn (#4236).
  if (parsed ? lines.length === 0 && asked.length === 0 && later.length === 0 && approvals.length === 0 && pulls.length === 0 && suggestions.length === 0
    : count === 0 && !keptPlace && deferred.length === 0) return null;
  const title = smartTitles[row];
  // How old the count is while the link is lost (#1163, #5141).
  const readAt = row === "needsYou" ? readSince : undefined;
  const updated = readAt !== undefined ? lastUpdateSpoken(readAt) : null;
  return (
    <details class={`smart ${row}`} role="group" aria-label={title} open={open}
      onToggle={(e) => {
        const now = (e.currentTarget as HTMLDetailsElement).open;
        if (now !== open) folds.setSmart(row, now);
      }}>
      <summary class="sidebar-head-label" data-fold={`smart.${row}`}
        aria-label={[title, count > 0 ? `${count}` : "none", updated].filter(Boolean).join(", ")}>
        {title}
        {readAt !== undefined && <LastUpdate at={readAt} />}
        {count > 0 && <span class={`count${row === "needsYou" ? " needs" : ""}`}>{count}</span>}
      </summary>
      {open && asked.map(({ host: on, folder: placed, request }) => {
        const host = on.id;
        return <RequestRow key={`${host}|${request.id}`} store={store} host={host} folder={placed?.folder.folder.folder ?? ""} request={request}
          place={placed ? placeOf(places, placed.host, placed.folder, store.macHostID.value) : ""}
          chosen={!!request.askedBy && r.host === host && r.session === request.askedBy} />;
      })}
      {open && lines.map((line) => {
        const host = line.host.id;
        const folder = line.folder.folder.folder;
        const down = linkDown || !store.hostIsOnline(host);
        const place = placeOf(places, line.host, line.folder, store.macHostID.value);
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
        const place = placeOf(places, placed.host, placed.folder, store.macHostID.value);
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
      {open && pulls.map(({ folder: placed, pull }) => {
        const host = placed.host.id;
        return <ReviewPullRow key={`${host}|${pull.url}`} store={store} host={host} folder={placed.folder.folder.folder} pull={pull}
          place={placeOf(places, placed.host, placed.folder, store.macHostID.value)} down={linkDown || !store.hostIsOnline(host)} />;
      })}
      {open && suggestions.map(({ folder: placed, suggestion }) => {
        const host = placed.host.id;
        return <CheckSuggestionRow key={`${host}|${suggestion.id}`} store={store} host={host} folder={placed.folder.folder.folder}
          suggestion={suggestion} place={placeOf(places, placed.host, placed.folder, store.macHostID.value)}
          down={linkDown || !store.hostIsOnline(host)} />;
      })}
      {open && later.length > 0 && <LaterGroup open={parsed !== undefined || folds.isLaterOpen()} count={later.length}>
        {later.map(({ host: on, folder: placed, request }) => {
          const host = on.id;
          return <RequestRow key={`${host}|${request.id}`} store={store} host={host} folder={placed?.folder.folder.folder ?? ""} request={request}
            place={placed ? placeOf(places, placed.host, placed.folder, store.macHostID.value) : ""}
            chosen={!!request.askedBy && r.host === host && r.session === request.askedBy} />;
        })}
      </LaterGroup>}
    </details>
  );
}

/**
 * Needs You's folded Later group (#4236), at its end, as the window's LaterRows: its heading folds it
 * and says how many, kept in localStorage as the other folds; its rows are the deferred requests,
 * each saying when it comes back. A search unfolds it.
 */
function LaterGroup({ open, count, children }: { open: boolean; count: number; children: ComponentChildren }) {
  return (
    <details class="later" role="group" aria-label="Later" open={open}
      onToggle={(e) => {
        const now = (e.currentTarget as HTMLDetailsElement).open;
        if (now !== open) folds.setLaterOpen(now);
      }}>
      <summary aria-label={`Later, ${count}`}>
        Later<span class="count">{count}</span>
      </summary>
      {open && children}
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
const FolderFold = memo(function FolderFold({ store, host, folder: summary, query, linkDown, alone: isAlone = false,
  others = [], groupName }: {
  store: Store; host: ControlMachine; folder: FolderSummary; query: string; linkDown: boolean;
  /** In a tab holding this folder alone (#1089): its rows under a Sessions heading, always open. */
  alone?: boolean;
  /** The project's other folders (#3278), whose live sessions are listed in this group too. */
  others?: Placed[];
  /** The group's name when it is a project's: the project's name. */
  groupName?: string | undefined;
}) {
  const r = route.value;
  const folder = summary.folder.folder;
  const label = groupName ?? folderLabel(host, summary, store.macHostID.value);
  const group: ProjectGroup<Placed> = { main: { host, folder: summary }, others };
  const macID = store.macHostID.value;
  const hostName = (id: string) => store.hosts.value.find((h) => h.id === id)?.name ?? id;
  const searching = query !== "";
  const unfolded = searching || isAlone || folds.isOpen(host.id, folder);
  const down = linkDown || !store.hostIsOnline(host.id);
  // Every match on show, past the first few; a new search shows the few again.
  const showsAllMatches = useSignal(false);
  const settingsOpen = useSignal<"project" | "folder" | null>(null);
  // Folder Settings of another folder of the project, chosen in Project Settings' Folders: that folder's fold opens it.
  const other = otherFolderSettings.value;
  useEffect(() => {
    if (other && other.host === host.id && folderKey(other.folder) === folderKey(folder)) {
      otherFolderSettings.value = null;
      settingsOpen.value = "folder";
    }
  }, [other]);
  useEffect(() => { showsAllMatches.value = false; }, [query]);
  const online = store.hostIsOnline(host.id);
  // A file dragged onto the row goes into the folder's drop box (#231). Before any early return:
  // it is a hook.
  const drop = useDropboxDrop(store, host.id, folder, down);
  // The list is held while the folder is open, and let go when it folds (#291).
  useEffect(() => {
    if (!unfolded || !online) return;
    store.holdWorkflows(host.id, folder);
    return () => store.releaseWorkflows(host.id, folder);
  }, [unfolded, online, host.id, folder]);

  const view = store.folderView(host.id, folder);
  // The matcher is made once per fold, not per row.
  const parsed = searching ? { ...parseQuery(query), said: store.saidLines.value, onIssue: store.issueSessions.value, issueHeadings: store.issueHeadings.value } : undefined;
  const live = view.headings.flatMap((h) => h.agents).filter((a) => isAlone || keptByState(a, stateFilter.value));
  // Those a group at the top lists are there alone (#495, #587), out of the folder's list. A
  // group turned off (#846) lists nothing, so its sessions are here unless the next group has them.
  const on = smartGroupsOn.value;
  const pins = store.sessionPinsIn(host.id, folder);
  // The one Unread keeps while it is open is listed there, not here too (#689).
  const keptID = !parsed && keptInUnread.value?.host === host.id ? keptInUnread.value.id : undefined;
  const keptAgent = keptID ? live.find((a) => a.id === keptID) : undefined;
  const kept = keptAgent && keepsInUnread(keptAgent, pins, on, keeper(keptInUnread.value?.hadFile ?? false, on)) ? keptAgent.id : undefined;
  // The project's other folders' live sessions too (#3278), each still its own folder's.
  const elsewhere = new Map<string, Placed>();
  const theirs = !unfolded ? [] : others.flatMap((placed) => {
    const listed = listedSessions(store, placed.host.id, placed.folder.folder.folder, parsed, on);
    for (const agent of listed) elsewhere.set(agent.id, placed);
    return listed;
  });
  const found = !unfolded ? [] : [...folderSessions(live, pins, parsed, kept, on), ...theirs].sort(byStart);
  const archivedFound = !unfolded || !parsed ? [] : view.archived.filter((a) => queryMatches(parsed, a));
  // A search for an epic (#3900): what it found here, live and archived, under a heading for each of its issues.
  const byIssue = parsed && groupsByIssue(parsed) ? issueGroups([...found, ...archivedFound], parsed) : [];
  const sessions = byIssue.length > 0 ? [] : found;
  const archived = byIssue.length > 0 ? [] : archivedFound;
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
  const nameMatches = label.toLowerCase().includes(query.toLowerCase());
  if (searching && sessions.length === 0 && archived.length === 0 && byIssue.length === 0 && workflows.length === 0
    && archivedWorkflows.length === 0 && !nameMatches) return null;

  const here = r.host === host.id && r.folder !== undefined && folderKey(r.folder) === folderKey(folder);
  const archivedSessionCount = summary.counts.archived ?? 0;
  const pageRow = (page: ArchiveRoute, mark: string, title: string, count: string) => (
    <div class="nav-item">
      <div class={`row page-row${here && r.archive === page ? " chosen" : ""}`}>
        <button class="pick" aria-current={here && r.archive === page} aria-label={`${title}, ${count}`}
          title={count} onClick={() => go({ host: host.id, folder: folder, archive: page })}>
          <Glyph of={mark} class="pin-mark" />
          <span class="title">{title}</span>
        </button>
      </div>
    </div>
  );
  // The project's connectors, one row for all its folders (#3407): this machine's folder, else the first online one.
  const connectors = connectorsPlace(group, store.macHostID.value, (h) => store.hostIsOnline(h));
  const connectorsHost = connectors.host.id;
  const connectorsFolder = connectors.folder.folder.folder;
  const mcpServers = folderServers(store.mcpHealthOf(connectorsHost), connectorsFolder);
  const mcpTally = healthTally(mcpServers);
  const endedConnection = store.endedInFolders.value[placeKey(connectorsHost, connectorsFolder)];
  const connectorsWords = [mcpTally?.words ?? "No connectors yet", endedConnection && endedLine([endedConnection])]
    .filter((w): w is string => !!w).join(". ");
  const connectorsHere = r.host === connectorsHost && r.folder !== undefined && folderKey(r.folder) === folderKey(connectorsFolder);
  const fold = (open: boolean) => folds.set(host.id, folder, open);
  const folderPinned = summary.folder.pinned === true;
  const folderMenu: MenuItem[] = [
    { label: "New Session", disabled: down, help: "Start a new session in this folder",
      run: () => go({ host: host.id, folder: folder, compose: true }) },
    // The project's folders on every machine (#3278), each with its machine and state: one opens it.
    ...(others.length === 0 ? [] : [
      { label: "Folders", disabled: true, run: () => {} },
      ...[group.main, ...others].map((placed) => ({
        label: folderLine(placed.folder.name, store.isMac(placed.host.id) ? "This Mac" : placed.host.name,
          machineState(store.hostIsOnline(placed.host.id), placed.host.workspace?.workspaceState)),
        disabled: linkDown || !store.hostIsOnline(placed.host.id), help: "Open this folder of the project",
        run: () => go({ host: placed.host.id, folder: placed.folder.folder.folder, compose: true }) })),
    ]),
    // The folder alone, in a tab of its own (#1089), as the window opens it in a window of its own.
    { label: "Open in New Tab", help: "Open this folder alone in a new browser tab",
      run: () => void window.open(aloneURL(host.id, folder), "_blank", "noopener") },
    { label: "Put Files in Drop Box…", disabled: down, help: "Put files into this folder's .agents/dropbox/ (#231)",
      run: () => putFilesInDropbox(host.id, folder, label) },
    // What the project's folders share, and what is this folder's alone (#3280), as the window's
    // Project Settings… and Folder Settings…. Agent Configuration, the Project and Cost on pull requests are in them.
    { label: projectSettingsWords.menuItem, disabled: down, help: "What every folder of this project shares",
      run: () => { settingsOpen.value = "project"; } },
    { label: projectSettingsWords.folderMenuItem, disabled: down, help: "This folder's place, project and disk space",
      run: () => { settingsOpen.value = "folder"; } },
    ...showHiddenViewsItem(store, host.id, folder, down),
    // To the top of the sidebar, as the window's Pin.
    { label: folderPinned ? "Unpin" : "Pin", disabled: down,
      help: folderPinned ? "Let this folder take its place among the others" : "Keep this folder at the top of the sidebar",
      run: () => void store.setFolderPinned(host.id, folder, !folderPinned) },
    // Into Archived folders, asked first (#668), as the window's Archive.
    { label: "Archive…", disabled: down, help: "Put this folder away in Archived folders",
      run: async () => {
        if (!await ask(`${archiveFolderTitle(label)}\n\n${archiveFolderMessage}`)) return;
        void store.archiveFolder(host.id, folder).then((summary) => {
          if (summary && here) go({ nav: "agents" });
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
  const row = (agent: Agent, tree?: TreeRow) => {
    // A session of the project's other folder is that folder's, and says its machine when elsewhere (#3278).
    const at = elsewhere.get(agent.id);
    const its = at?.host.id ?? host.id;
    return (
      <SidebarSession key={`${its}|${agent.id}`} store={store} host={its} folder={at?.folder.folder.folder ?? folder} agent={agent}
        chosen={r.host === its && r.session === agent.id} down={at ? linkDown || !store.hostIsOnline(its) : down} tree={tree}
        place={machineMark(group, its, macID, hostName)} />
    );
  };
  // Each under the session that started it, folded (#835).
  const sessionRows = treeRows(sessions, (id) => others.length > 0 ? startedByOf(store, id) : store.agent(host.id, id)?.startedByAgent,
    (id) => folds.isSessionOpen(id));
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
      {settingsOpen.value === "project" && <ProjectSettingsModal store={store} host={host.id} folder={folder} summary={summary}
        down={down} close={() => { settingsOpen.value = null; }}
        openFolder={(h, f) => {
          settingsOpen.value = null;
          if (h === host.id && folderKey(f) === folderKey(folder)) settingsOpen.value = "folder";
          else otherFolderSettings.value = { host: h, folder: f };
        }} />}
      {settingsOpen.value === "folder" && <FolderSettingsModal store={store} host={host.id} folder={folder} summary={summary}
        down={down} close={() => { settingsOpen.value = null; }} openProject={() => { settingsOpen.value = "project"; }} />}
      {isAlone ? (
        // The tab is the folder, so its name is the tab's title and not a heading (#1089).
        <p class={`sidebar-head-label alone-sessions${drop.targeted ? " drop-target" : ""}`} {...drop.props}>Sessions</p>
      ) : (
      <div class={`row folder${drop.targeted ? " drop-target" : ""}`} {...drop.props}>
        <button class="disclosure" aria-label={unfolded ? `Fold ${label}` : `Unfold ${label}`} aria-expanded={unfolded}
          tabIndex={-1} disabled={searching} onClick={() => fold(!unfolded)}><Icon name={unfolded ? "chevron-down" : "chevron-right"} /></button>
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
          {/* A search for an epic (#3900): a heading for each issue, the epic's own first, held open as a search holds Sessions. */}
          {byIssue.map((group) => (
            <div class="issue-group" role="group" key={group.issue.node.ref} aria-label={`${group.title}, ${group.sessions.length}`}>
              <div class="issue-group-heading" title={group.title} aria-hidden="true">
                <span class="title">{group.title}</span><span class="count">{group.sessions.length}</span>
              </div>
              {treeRows(group.sessions, (id) => others.length > 0 ? startedByOf(store, id) : store.agent(host.id, id)?.startedByAgent,
                (id) => folds.isSessionOpen(id)).map((tree) => row(tree.agent, tree))}
            </div>
          ))}
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
          {/* Its connectors (#753), under every group even with none yet (#1422): a page, red when one does not answer or a
              slot's connection ended (#3407), with how many after the title, small and grey, none at zero (#1569). */}
          <div class="nav-item">
            <div class={`row page-row${connectorsHere && r.mcp ? " chosen" : ""}`}>
              <button class="pick" aria-current={connectorsHere && !!r.mcp} aria-label={`Connectors, ${mcpTally || endedConnection ? connectorsWords : "none yet"}`}
                title={connectorsWords} onClick={() => go({ host: connectorsHost, folder: connectorsFolder, mcp: true })}>
                <Icon name="plug" class={`pin-mark${mcpTally?.failing || endedConnection ? " warns" : ""}`} />
                <span class="title">Connectors{mcpServers.length > 0 && <span class="count">{mcpServers.length}</span>}</span>
              </button>
            </div>
          </div>
          {/* Archived Sessions and Archived Workflows (#495, #4451): a row each opening its page, never a fold inside
              the group, each only with something archived. Nothing at its end, which is only a session's (#587): the
              count is its tooltip's. */}
          {archivedSessionCount > 0 && pageRow("sessions", "▣", sessionsWords.title, sessionCount(archivedSessionCount))}
          {archivedWorkflows.length > 0 && pageRow("workflows", "◷", workflowsWords.title, workflowCount(archivedWorkflows.length))}
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
  store: Store; host: ControlMachine; folder: FolderSummary; down: boolean;
}) {
  const folder = summary.folder.folder;
  const archivedAt = summary.folder.archivedAt;
  const label = folderLabel(host, summary, store.macHostID.value);
  const unarchive = async () => {
    if (await store.unarchiveFolder(host.id, folder)) go({ host: host.id, folder: folder, compose: true });
  };
  const remove = async () => {
    if (await ask(`${deleteFolderTitle(label)}\n\n${deleteFolderMessage}`)) void store.deleteFolder(host.id, folder);
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
export const SidebarSession = memo(function SidebarSession({ store, host, folder, agent, chosen, down, pinnedAt, place, tree, archivedTime }: {
  store: Store; host: string; folder: string; agent: Agent; chosen: boolean; down: boolean;
  /** On the Archived Sessions page (#4451): the time is when it was archived, not its last activity. */
  archivedTime?: boolean | undefined;
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
      store.has(host, Capability.mute1), canMoveOn(store, host), store.has(host, Capability.agentsStartNow1)).map(({ action, label: words, help, shortcut }) => ({
      label: words, help, disabled: down || !!store.onItsWay.value[agent.id], ...shortcut ? { shortcut } : {},
      run: () => runSessionAction(store, host, agent, action),
    })),
    // A question it asked, out of Needs You for an hour, as l does (#4796).
    ...laterItem(store, host, agent, down),
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
  const treeClass = `${tree?.isChild ? " child" : ""}${parent ? " parent" : ""}`;
  return (
    <>
    <div class={`nav-item${treeClass}${drop.targeted ? " drop-target" : ""}`}
      style={tree?.isChild ? { "--indent": tree.indent } : undefined} onContextMenu={(e) => openContextMenu(e, menu())}
      onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, menu()); }} {...holdForMenu(menu)} {...drop.props}
      // Its chat fetched while the pointer rests on it, so a click draws it at once (#4795).
      {...(down ? {} : prefetchOnHover(() => { void store.prefetch(host, agent.id); }))}
      // A double-click edits its title in the row, as the window's does (#1518).
      onDblClick={(e) => {
        if (agent.state === "archived" || (e.target as HTMLElement).closest(".fold-count, .renaming")) return;
        e.preventDefault();
        runSessionAction(store, host, agent, "rename");
      }}>
      {/* No wait lines: in the sidebar a session's row is its title and one line (#587). */}
      {store.renaming.value?.id === agent.id && !store.renaming.value.inChat
        ? <div class="row session renaming"><RenameInput store={store} host={host} agent={agent} /></div>
        : <SessionRow agent={agent} chosen={chosen} onPick={() => { if (chosen) store.toEndAsks.value++; store.putAwayMove(agent.id); go({ host, folder: folder, session: agent.id }); }} going={going}
        extras={rowExtras(store, host, agent)}
        inSidebar place={place} markAgent={markAgent} archivedTime={archivedTime} />}
      {parent && (
        <button class="fold-count" aria-expanded={tree.isUnfolded}
          aria-label={tree.isUnfolded ? `Hide ${tree.children} started sessions` : `Show ${tree.children} started sessions`}
          title={tree.isUnfolded ? "Hide the sessions it started" : `Show the ${tree.children} sessions it started`}
          onClick={() => folds.setSession(agent.id, !tree.isUnfolded)}>
          {tree.children}<Icon name="chevron-right" class={`chevron${tree.isUnfolded ? " open" : ""}`} />
        </button>
      )}
    </div>
    <DropNote note={drop.note} />
    </>
  );
});

/** Later on the request a session asked (#4796), in its row's menu, with l; none when it asked none. */
function laterItem(store: Store, host: string, agent: Agent, down: boolean): MenuItem[] {
  const request = agent.state === "archived" ? undefined : laterRequestOf(store, host, agent);
  return request ? [{ label: laterWords[laterTime], help: "Out of Needs You until then", shortcut: listKeyGlyph.later,
    disabled: down, run: () => void store.deferRequest(host, request.id, laterTime) }] : [];
}

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

