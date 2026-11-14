// The bar of sections at the top of every page (#2141), in place of Workspace | Console | Reports
// (#1804), and every section but the Overview and Agents drawn as the Console was: its list of pages
// on the left, the page open on the right. Below 760 the bar is one menu with the open section's
// name. g then a letter goes to a section, when the focus is not in a field; ⌘K opens the command menu (#4788).
import { forgeHosts, loadList, workList } from "../model/workLists";
import type { WorkKind } from "../model/work";
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import { Fragment, type ComponentChildren } from "preact";
import type { Store } from "../model/store";
import { go, route, sectionOf, usageAsked } from "../route";
import { gated, groupedPages, machinePages, navPages, navTitle, openPage, pagesShown, sectionKeys, sectionsShown, usagePaneTitle, usagePanes,
  type NavPage, type NavSection, pageRoute, routePageID } from "../model/nav";
import { adminOf, adminsOnly } from "../model/console";
import { hostAnswers, stateWords, versionWords } from "../model/capabilities";
import { needingYou, placedSessions } from "../model/overview";
import { ActivityPageView } from "./Activity";
import { ConsoleSection, MachinesPage, roleProblemOf } from "./ConsoleApp";
import { requestCount } from "./ConsoleRecords";
import { policyNotSaved } from "./ConsolePolicy";
import { orgPolicyNotSaved } from "./ConsoleOrgPolicy";
import { ReportsPage } from "./Reports";
import { BuildsPage } from "./Builds";
import { WorkList, WorkPage } from "./Work";
import { WorkReleasePage } from "./WorkRelease";
import { WorkFeatures } from "./WorkFeatures";
import { WorkTimeline } from "./WorkTimeline";
import { WorkDeploysPage } from "./WorkDeploysPage";
import { DocPage, DocsList } from "./Docs";
import { ConversationPage, MessagesList } from "./Messages";
import { MachinePage } from "./MachinePage";
import { machineNeed, machineNeedLine } from "./OfflineStrip";
import { MachineRow, MakingRow } from "./MachineRow";
import { deleteMakingQuestion, joinTrustQuestion, type MachineMaking, makingRows, newMachineItems } from "../model/machineRow";
import { openContextMenu, type MenuItem } from "./ContextMenu";
import { AddMachineDialog } from "./AddMachineDialog";
import { addMachineWords } from "../model/addMachine";
import { SettingsPage } from "./Settings";
import { SecretsSection } from "./UserScope";
import { AccountsSection } from "./Accounts";
import { StatusListMark, StatusListLastLine, StatusSecretsPage, useUserScopeStatus } from "./StatusSecrets";
import { SessionSecretsSection } from "./settings/SessionSecrets";
import { LocalSecretsSection } from "./settings/LocalSecrets";
import { WorkflowRow } from "./WorkflowRow";
import { BackToList } from "./BackToList";
import { DataTable } from "./DataTable";
import { PageTitle, PersonMenu, SearchBox } from "./TopBar";
import { pageCrumbs, type Crumb } from "../model/crumbs";
import { MultiplierPage } from "./Multiplier";
import { lowDetail, lowWords, runtimeTally, setupRuntimes } from "../model/runtimes";
import { eventsWaitingLine } from "../model/eventsWaiting";
import type { Session } from "../session";
import { ask } from "./MessageKinds";
import { CommandMenu } from "./CommandMenu";
import { Icon } from "./Icon";

/**
 * How many requests and sessions need the person, across every folder: Agents' count in the bar.
 * Requests, not sessions (#3864): each open request, and each session needing the person that asked none;
 * a terminal's agents-secret too (#4179). A request in Later counts nothing, and its asker neither (#4236).
 */
export function needsYouCount(store: Store): number {
  const folders = store.hosts.value.flatMap((h) => (store.folders.value[h.id] ?? [])
    .filter((f) => f.folder.archivedAt === undefined).map((f) => ({ host: h.id, folder: f.folder.folder })));
  const requests = folders.flatMap(({ host, folder }) => store.personRequestsIn(host, folder));
  const askers = new Set(folders.flatMap(({ host, folder }) => store.openPersonRequestsIn(host, folder)
    .map((r) => `${host}|${r.askedBy}`)));
  const sessions = needingYou(placedSessions(store.hosts.value, store.folders.value,
    (h, f) => store.folderView(h, f).headings.flatMap((x) => x.agents)))
    .filter((p) => !askers.has(`${p.host.id}|${p.agent.id}`));
  // A terminal's agents-secret (#4179) is in no folder.
  const terminal = store.hosts.value.reduce((n, h) => n + store.terminalRequests(h.id).length, 0);
  return requests.length + sessions.length + terminal;
}

function countOf(store: Store, section: NavSection, admin: boolean | null): number {
  if (section === "agents") return needsYouCount(store);
  if (section === "requests" && admin === true) return requestCount(store);
  return 0;
}

/** The sections, at the top of every page. */
export function NavBar({ store, session }: { store: Store; session: Session }) {
  const r = route.value;
  const current = sectionOf(r);
  const admin = adminOf(store);
  const shown = sectionsShown(admin, current);
  const name = store.plane.value?.name || "Control plane";
  const menuOpen = useSignal(false);
  // g then a letter: to a section, as a mail app's keys go to a mailbox.
  useEffect(() => {
    let armed = 0;
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      if (e.metaKey || e.ctrlKey || e.altKey || target?.closest("input, textarea, select, [contenteditable=true]")) return;
      if (e.key === "g") { armed = Date.now(); return; }
      const to = sectionKeys[e.key];
      if (armed && Date.now() - armed < 1500 && to && sectionsShown(adminOf(store), sectionOf(route.peek())).includes(to)) {
        e.preventDefault();
        go(to === "overview" ? {} : { nav: to });
      }
      armed = 0;
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  }, []);
  const to = (s: NavSection) => { menuOpen.value = false; go(s === "overview" ? {} : { nav: s }); };
  const item = (s: NavSection) => {
    const count = countOf(store, s, admin);
    return (
      <button key={s} type="button" class={`nav-item${s === current ? " on" : ""}`} aria-current={s === current ? "page" : undefined}
        aria-label={count ? `${navTitle[s]}, ${count} waiting` : undefined} onClick={() => to(s)}>
        {navTitle[s]}{count > 0 && <span class="sub-app-count" aria-hidden="true">{count}</span>}
      </button>
    );
  };
  return (
    <header class="top-bar">
      <nav class="nav-bar" aria-label="Sections">
        <button type="button" class="nav-home" onClick={() => to("overview")}>{name}</button>
        <div class="nav-items wide-only">{shown.map(item)}</div>
        <div class="nav-menu narrow-only">
          <button type="button" class="nav-menu-button" aria-expanded={menuOpen.value} onClick={() => { menuOpen.value = !menuOpen.value; }}>
            {navTitle[current]} <Icon name={menuOpen.value ? "chevron-up" : "chevron-down"} />
            {!menuOpen.value && shown.some((s) => countOf(store, s, admin) > 0) && <span class="sub-app-count" aria-hidden="true">•</span>}
          </button>
          {menuOpen.value && <div class="nav-menu-list">{shown.map(item)}</div>}
        </div>
      </nav>
      <SearchBox store={store} />
      <PersonMenu store={store} session={session} />
      <CommandMenu store={store} />
    </header>
  );
}

/** Status ▸ Runtimes' grey line (#3956), as the window's Runtimes row: each runtime read on the machine the page reads
 * it on. `detail` is the title's and a screen reader's, with the reset when it is on course to run out (#5000). */
function runtimesLowWords(store: Store): { words: string; detail: string } | undefined {
  const all = setupRuntimes(store.hosts.value, store.macHostID.value, store.runtimes.value);
  const home = new Map(all.map((r) => [r.status.runtime.id, r.home]));
  const tally = runtimeTally(all.map((r) => r.status), (id) => store.runtimeAllowances.value[home.get(id) ?? ""]);
  const words = lowWords(tally);
  return words ? { words, detail: lowDetail(tally) ?? words } : undefined;
}

const isRuntimesPage = (page: NavPage) => page.draw.kind === "activity" && page.draw.page === "runtimes";

/** A page's mark beside its row in the list: a count, or that it is not saved. */
function PageMark({ store, page }: { store: Store; page: NavPage }) {
  // Status ▸ Secrets and Accounts (#4161): the newest operation's age.
  if (page.draw.kind === "statusList") return <StatusListMark store={store} list={page.draw.list} />;
  // Status ▸ Runtimes (#3956): an allowance below 10% left or on course to run out (#5000), in the warning tint, as the window's orange Runtimes icon.
  if (isRuntimesPage(page)) {
    const low = runtimesLowWords(store);
    if (low) return <span class="small attention" title={low.detail} aria-hidden="true">●</span>;
  }
  if (page.id === "requests" && requestCount(store) > 0) return <span class="sub-app-count">{requestCount(store)}</span>;
  if (page.id === "reportPolicy" && policyNotSaved(store)) return <span class="quiet small attention">Not saved</span>;
  if (page.id === "policy" && orgPolicyNotSaved(store)) return <span class="quiet small attention">Not saved</span>;
  // Connectors: a connector of the person's that does not answer, or a connection that ended (#3407), as the window's red icon.
  if (page.id === "mcp") {
    const words = store.connectorsWarning();
    if (words) return <span class="small failure" title={words} aria-label={words}>●</span>;
  }
  return null;
}

/** Under a machine's row (#3764), in grey: the most urgent thing it needs; Start is in the row's menu and swipe (#3974).
 * Nothing when it needs nothing. The window's MachineRow. A sign-in is what its runtimes last said. */
function MachineNeedLine({ store, host }: { store: Store; host: string }) {
  const row = store.hosts.value.find((h) => h.id === host);
  const need = row ? machineNeed(row, store.hostIsOnline(host), store.runtimes.value[host] ?? [],
    store.disk.value[host]?.alarms ?? [], store.capacity.value[host]?.level) : null;
  if (!row || !need) return null;
  return (
    <p class="machine-need quiet small" role="status">{machineNeedLine(need, row)}</p>
  );
}

/** Under Status ▸ Runtimes (#3956), in grey: `Claude: 8% left`, or `Claude: runs out Fri at this pace` (#5000). Nothing when no allowance is low, or none work. */
function RuntimesLowLine({ store }: { store: Store }) {
  const low = runtimesLowWords(store);
  return low ? <p class="page-need quiet small" role="status" title={low.detail} aria-label={low.detail}>{low.words}</p> : null;
}

const isEventsPage = (page: NavPage) => page.draw.kind === "activity" && page.draw.page === "events";

/** Under Status ▸ Events, in grey: `4 sessions waiting`, as the window's Events row. Nothing when none waits;
 * no time, as a wait's age says nothing. */
function EventsWaitingLine({ store }: { store: Store }) {
  const words = eventsWaitingLine(store.events.value);
  return words ? <p class="page-need quiet small" role="status">{words}</p> : null;
}

/** A section's list of pages on the left, the page open on the right. */
export function SectionPage({ store, section, down }: { store: Store; section: Exclude<NavSection, "overview" | "agents">; down: boolean }) {
  const admin = adminOf(store);
  const r = route.value;
  // A page per machine under Machines (#3626).
  const more = section === "machines" ? machinePages(store.hosts.value, store.macHostID.value) : [];
  const open = openPage(section, routePageID(section, r), admin, more);
  const list = pagesShown(section, admin, open?.id, more);
  const registering = useSignal(false);
  useUserScopeStatus(store, section === "status");
  // Work shown: the list it opens on read ahead (#4930), from this device's copy and then the machines, so it draws at once.
  const forgeOn = forgeHosts(store).map((h) => h.id).join(",");
  useEffect(() => {
    if (section !== "work" || !forgeOn) return;
    const kind: WorkKind = r.section === "pr" || r.section === "release" ? r.section : "issue";
    const l = workList(kind);
    if (l.lists.peek() === null && !l.loading.peek()) void loadList(store, l);
  }, [section, forgeOn]);
  // Status ▸ Events' grey line reads who waits on each machine that answers; events/changed keeps it.
  const online = store.hosts.value.filter((h) => hostAnswers(h.state)).map((h) => h.id);
  useEffect(() => {
    if (section === "status") for (const host of online) void store.loadEvents(host);
  }, [section, online.join(",")]);
  // The Machines header (#3974): its menu has New Machine and registers one. New Machine itself is the group's
  // last row, + New Machine, as the Remote's (#4034, #5265); a click opens its sheet (#4634).
  const machinesHead = (group: string) => section === "machines" && group === "Machines";
  // With two or more providers, New Machine names the default, and New Machine on ‹name› opens the sheet on another (#3979).
  useEffect(() => {
    if (section === "machines" && store.providers.list.value === null) void store.providers.load();
  }, [section]);
  const headItems = (): MenuItem[] => [
    ...newMachineItems(store.providers.list.value ?? []).map((item) => ({ label: item.label, run: () => store.newMachine(item.provider) })),
    { label: addMachineWords.menuItem, run: () => { registering.value = true; } },
  ];
  return (
    <div class={`columns sub-app console${list.length > 1 ? "" : " one-page"}`} aria-busy={down}>
      {list.length > 1 && (
        <nav class="folders sub-app-list" aria-label={navTitle[section]}>
          {groupedPages(list).map(([group, pages]) => (
            <div key={group} class="sub-app-group">
              {machinesHead(group) ? (
                <h2 class="section-head" onContextMenu={(e) => openContextMenu(e, headItems())}>{group}</h2>
              ) : <h2 class="section-head">{group}</h2>}
              {pages.map((p) => p.draw.kind === "machine" ? (
                <MachineRow key={p.id} store={store} host={p.draw.host} on={p.id === open?.id}
                  open={() => go({ nav: section, section: p.id })}>
                  <MachineNeedLine store={store} host={p.draw.host} />
                </MachineRow>
              ) : (
                <Fragment key={p.id}>
                  <button type="button" class={`sub-app-row${p.id === open?.id ? " on" : ""}${p.under ? " under" : ""}`}
                    aria-current={p.id === open?.id ? "page" : undefined} onClick={() => go(pageRoute(section, p))}>
                    {p.title}
                    <PageMark store={store} page={p} />
                  </button>
                  {isRuntimesPage(p) && <RuntimesLowLine store={store} />}
                  {isEventsPage(p) && <EventsWaitingLine store={store} />}
                  {p.draw.kind === "statusList" && <StatusListLastLine store={store} list={p.draw.list} />}
                </Fragment>
              ))}
              {machinesHead(group) && makingRows(store.machinesMaking.value, store.providers.list.value, store.hosts.value)
                .map((row) => <MakingRow key={`making-${row.provider}/${row.workspace}/${row.name}`} row={row}
                  join={store.machineJoins.value[`${row.provider}/${row.workspace}`]}
                  onDelete={async () => { if (await ask(deleteMakingQuestion(row))) void store.deleteWorkspace(row.provider, row.workspace); }}
                  onJoin={() => void joinAsking(store, row)} />)}
              {machinesHead(group) && (
                <button type="button" class="sub-app-row new-machine-row" title="New Machine: choose what the provider makes, starting from the options used last"
                  onClick={() => store.newMachine()}
                  onContextMenu={(e) => openContextMenu(e, headItems().slice(0, -1))}>
                  <span><Icon name="plus" class="new-mark" /> New Machine</span>
                </button>
              )}
            </div>
          ))}
        </nav>
      )}
      {open && <PageView store={store} page={open} down={down} />}
      {registering.value && <AddMachineDialog store={store} close={() => { registering.value = false; }} />}
    </div>
  );
}

/** A click on a machine that never joined (#4978): a host key new to the control plane is asked about first. */
async function joinAsking(store: Store, row: MachineMaking): Promise<void> {
  await store.joinMachine(row);
  const join = store.machineJoins.value[`${row.provider}/${row.workspace}`];
  if (!join || !("needsTrust" in join)) return;
  if (await ask(joinTrustQuestion(row, join.needsTrust))) await store.joinMachine(row, join.needsTrust);
  else store.cancelJoin(row);
}

/** One page of a section, in the chat's place: Agents' Live Now and Projects too. */
export function PageView({ store, page, down }: { store: Store; page: NavPage; down: boolean }) {
  const section = sectionOfPage(page);
  const admin = adminOf(store);
  if (!gated(page, admin) && page.draw.kind === "activity") return <ActivityPageView store={store} page={page.draw.page} />;
  if (!gated(page, admin) && page.draw.kind === "settings") return <SettingsPage store={store} down={down} />;
  if (page.draw.kind === "multiplier") return <MultiplierPage store={store} />;
  // A page under another (#5178) names that page in its breadcrumb: Reports › Planning › Builds.
  const parent = page.under ? navPages[section].find((p) => p.id === page.under) : undefined;
  return (
    <Framed title={page.title} section={section} parent={parent && { title: parent.title, to: { nav: section, section: parent.id } }}>
      {gated(page, admin) ? <p class="hint">{admin === null ? "Loading…" : roleProblemOf(store) ?? adminsOnly}</p>
        : page.draw.kind === "console" ? <ConsoleSection store={store} id={page.draw.id} down={down} />
        : page.draw.kind === "report" ? <ReportsPage store={store} section={page.draw.section} down={down} />
        : page.draw.kind === "builds" ? <BuildsPage store={store} down={down} />
        : page.draw.kind === "machines" ? (admin === true ? <MachinesPage store={store} down={down} /> : <YourMachines store={store} />)
        : page.draw.kind === "workflows" ? <AllWorkflows store={store} down={down} />
        : page.draw.kind === "usage" ? <Usage store={store} />
        // An item of a list Work no longer has (#/work/milestone/<ref>, #3878) opens the Work default's list.
        : page.draw.kind === "work" ? (route.value.item && route.value.section === page.id
          ? page.draw.work === "release"
            ? <WorkReleasePage key={route.value.item} store={store} ref={route.value.item} />
            : <WorkPage key={route.value.item} store={store} kind={page.draw.work} ref={route.value.item} />
          : <WorkList key={page.draw.work} store={store} kind={page.draw.work} />)
        : page.draw.kind === "machine" ? <MachinePage key={page.draw.host} store={store} host={page.draw.host} />
        : page.draw.kind === "features" ? <WorkFeatures store={store} />
        : page.draw.kind === "timeline" ? <WorkTimeline store={store} />
        : page.draw.kind === "deploys" ? <WorkDeploysPage store={store} />
        // The person's secrets and cards (#1760), then a machine's for one session (#3548), then what agents saved
        // on that machine (#5122); were in Settings ▸ Machines.
        : page.draw.kind === "secrets" ? <><SecretsSection store={store} down={down} /><SessionSecretsSection store={store} down={down} />
          <LocalSecretsSection store={store} down={down} /></>
        : page.draw.kind === "accounts" ? <AccountsSection store={store} down={down} />
        : page.draw.kind === "statusList" ? <StatusSecretsPage store={store} list={page.draw.list} />
        : page.draw.kind === "docs" ? (route.value.item
          ? <DocPage key={route.value.item} store={store} docRef={route.value.item} />
          : <DocsList store={store} />)
        : page.draw.kind === "messages" ? (route.value.item
          ? <ConversationPage key={route.value.item} store={store} conversationKey={route.value.item} />
          : <MessagesList store={store} />) : null}
    </Framed>
  );
}

/** The section a page is in, for its breadcrumb. */
function sectionOfPage(page: NavPage): Exclude<NavSection, "overview"> {
  if (page.draw.kind === "machine") return "machines";
  return (Object.keys(navPages) as NavSection[]).find((s) => navPages[s].includes(page)) as Exclude<NavSection, "overview"> ?? "agents";
}

function Framed({ title, section, parent, children }: { title: string; section: Exclude<NavSection, "overview">; parent?: Crumb | undefined;
  children: ComponentChildren }) {
  const crumbs = pageCrumbs(section, title);
  return (
    <section class="chat activity-page sub-app-page console" aria-label={title}>
      <header class="column-head page-head"><BackToList />
        <PageTitle parts={parent ? [...crumbs.slice(0, -1), parent, ...crumbs.slice(-1)] : crumbs}><h1>{title}</h1></PageTitle></header>
      <div class="scroll">
        <div class="activity-body settings-body">{children}</div>
      </div>
    </section>
  );
}

/** A member's Machines: the machines this page knows, theirs and the ones shared with them. */
function YourMachines({ store }: { store: Store }) {
  const hosts = store.hosts.value;
  return (
    <DataTable id="yourMachines" label="Machines" rows={hosts} rowKey={(h) => h.id} order={{ column: "name", dir: "asc" }}
      empty="No machines yet. Add one under Machines in the sidebar." columns={[
        { id: "name", title: "Machine", sort: (h) => h.name,
          cell: (h) => <><span class="strong">{h.name}</span><br /><span class="quiet small">{h.workspace?.providerName || h.platform}</span></> },
        { id: "state", title: "State", sort: stateWords, cell: (h) => <span class={`fleet-state ${h.state}`}>{stateWords(h)}</span> },
        { id: "version", title: "Version", sort: (h) => h.version, cell: versionWords },
      ]} />
  );
}

/** Every folder's workflows in one list, by folder: the same rows as each folder's Workflows fold. */
function AllWorkflows({ store, down }: { store: Store; down: boolean }) {
  const hosts = store.hosts.value;
  const folders = hosts.flatMap((host) => (store.folders.value[host.id] ?? [])
    .filter((f) => f.folder.archivedAt === undefined).map((folder) => ({ host, folder })));
  const several = hosts.length > 1;
  const key = folders.filter(({ host }) => hostAnswers(host.state)).map(({ host, folder }) => `${host.id}|${folder.folder.folder}`).join(",");
  // Held while the page is open, and let go when it closes, as a folder's fold holds its list (#291).
  useEffect(() => {
    const held = folders.filter(({ host }) => hostAnswers(host.state));
    for (const { host, folder } of held) store.holdWorkflows(host.id, folder.folder.folder);
    return () => { for (const { host, folder } of held) store.releaseWorkflows(host.id, folder.folder.folder); };
  }, [key]);
  const groups = folders.map(({ host, folder }) => ({ host, folder, list: store.folderWorkflows(host.id, folder.folder.folder) }))
    .filter((g) => g.list.length > 0);
  if (groups.length === 0) return <p class="hint">No workflows yet. A workflow is a file in a folder's .agents/workflows.</p>;
  return (
    <>
      {groups.map(({ host, folder, list }) => (
        <section key={`${host.id}|${folder.folder.folder}`} class="all-workflows">
          <h2 class="section-head">{several ? `${host.name}: ${folder.name}` : folder.name}</h2>
          {list.map((summary) => (
            <WorkflowRow key={summary.workflow.workflowID} store={store} host={host.id} summary={summary}
              disabled={down || !hostAnswers(host.state)} chosen={false}
              onPick={() => go({ host: host.id, folder: folder.folder.folder, workflow: summary.workflow.workflowID })} />
          ))}
        </section>
      ))}
    </>
  );
}

/** Usage: what was Activity's Cost, Tokens and Time, your own machines' (#956). */
function Usage({ store }: { store: Store }) {
  const pane = useSignal(usageAsked.peek() ?? "spending");
  return (
    <>
      <div class="tabs" role="tablist" aria-label="Show">
        {usagePanes.map((p) => (
          <button key={p} role="tab" aria-selected={pane.value === p} class={pane.value === p ? "on" : ""}
            onClick={() => { pane.value = p; usageAsked.value = undefined; }}>{usagePaneTitle[p]}</button>
        ))}
      </div>
      <div class="usage-pane"><ActivityPageView key={pane.value} store={store} page={pane.value} /></div>
    </>
  );
}
