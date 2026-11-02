// The bar of sections at the top of every page (#2141), in place of Workspace | Console | Reports
// (#1804), and every section but the Overview and Agents drawn as the Console was: its list of pages
// on the left, the page open on the right. Below 760 the bar is one menu with the open section's
// name. g then a letter goes to a section, when the focus is not in a field.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { ComponentChildren } from "preact";
import type { Store } from "../model/store";
import { go, route, sectionOf, usageAsked } from "../route";
import { gated, groupedPages, navPages, navTitle, openPage, pagesShown, sectionKeys, sectionsShown, usagePaneTitle, usagePanes,
  type NavPage, type NavSection } from "../model/nav";
import { adminOf, adminsOnly } from "../model/console";
import { hostAnswers, stateWords, versionWords } from "../model/capabilities";
import { needingYou, placedSessions } from "../model/overview";
import { ActivityPageView } from "./Activity";
import { ConsoleSection, MachinesPage, roleProblemOf } from "./ConsoleApp";
import { requestCount } from "./ConsoleRecords";
import { policyNotSaved } from "./ConsolePolicy";
import { orgPolicyNotSaved } from "./ConsoleOrgPolicy";
import { ReportsPage } from "./Reports";
import { LineagePage } from "./Lineage";
import { WorkList, WorkPage } from "./Work";
import { SettingsPage } from "./Settings";
import { WorkflowRow } from "./WorkflowRow";
import { BackToList } from "./BackToList";
import { DataTable } from "./DataTable";
import { PageTitle, PersonMenu, SearchBox } from "./TopBar";
import { pageCrumbs } from "../model/crumbs";
import type { Session } from "../session";

/** How many sessions need the person, across every folder: Agents' count in the bar. */
export function needsYouCount(store: Store): number {
  return needingYou(placedSessions(store.hosts.value, store.folders.value,
    (h, f) => store.folderView(h, f).headings.flatMap((x) => x.agents))).length;
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
            {navTitle[current]} {menuOpen.value ? "▴" : "▾"}
            {!menuOpen.value && shown.some((s) => countOf(store, s, admin) > 0) && <span class="sub-app-count" aria-hidden="true">•</span>}
          </button>
          {menuOpen.value && <div class="nav-menu-list">{shown.map(item)}</div>}
        </div>
      </nav>
      <SearchBox store={store} />
      <PersonMenu store={store} session={session} />
    </header>
  );
}

/** A page's mark beside its row in the list: a count, or that it is not saved. */
function PageMark({ store, page }: { store: Store; page: NavPage }) {
  if (page.id === "requests" && requestCount(store) > 0) return <span class="sub-app-count">{requestCount(store)}</span>;
  if (page.id === "reportPolicy" && policyNotSaved(store)) return <span class="quiet small attention">Not saved</span>;
  if (page.id === "policy" && orgPolicyNotSaved(store)) return <span class="quiet small attention">Not saved</span>;
  return null;
}

/** A section's list of pages on the left, the page open on the right. */
export function SectionPage({ store, section, down }: { store: Store; section: Exclude<NavSection, "overview" | "agents">; down: boolean }) {
  const admin = adminOf(store);
  const r = route.value;
  const open = openPage(section, r.section, admin);
  const list = pagesShown(section, admin, open?.id);
  return (
    <div class="columns sub-app console" aria-busy={down}>
      {list.length > 1 && (
        <nav class="folders sub-app-list" aria-label={navTitle[section]}>
          {groupedPages(list).map(([group, pages]) => (
            <div key={group} class="sub-app-group">
              <h2 class="section-head">{group}</h2>
              {pages.map((p) => (
                <button key={p.id} type="button" class={`sub-app-row${p.id === open?.id ? " on" : ""}`}
                  aria-current={p.id === open?.id ? "page" : undefined} onClick={() => go({ nav: section, section: p.id })}>
                  {p.title}
                  <PageMark store={store} page={p} />
                </button>
              ))}
            </div>
          ))}
        </nav>
      )}
      {open && <PageView store={store} page={open} down={down} />}
    </div>
  );
}

/** One page of a section, in the chat's place: Agents' Live Now and Projects too. */
export function PageView({ store, page, down }: { store: Store; page: NavPage; down: boolean }) {
  const section = sectionOfPage(page);
  const admin = adminOf(store);
  if (!gated(page, admin) && page.draw.kind === "activity") return <ActivityPageView store={store} page={page.draw.page} />;
  if (!gated(page, admin) && page.draw.kind === "settings") return <SettingsPage store={store} down={down} />;
  return (
    <Framed title={page.title} section={section}>
      {gated(page, admin) ? <p class="hint">{admin === null ? "Loading…" : roleProblemOf(store) ?? adminsOnly}</p>
        : page.draw.kind === "console" ? <ConsoleSection store={store} id={page.draw.id} down={down} />
        : page.draw.kind === "report" ? <ReportsPage store={store} section={page.draw.section} down={down} />
        : page.draw.kind === "machines" ? (admin === true ? <MachinesPage store={store} down={down} /> : <YourMachines store={store} />)
        : page.draw.kind === "workflows" ? <AllWorkflows store={store} down={down} />
        : page.draw.kind === "usage" ? <Usage store={store} />
        : page.draw.kind === "lineage" ? <LineagePage store={store} />
        : page.draw.kind === "work" ? (route.value.item
          ? <WorkPage key={route.value.item} store={store} kind={page.draw.work} ref={route.value.item} />
          : <WorkList key={page.draw.work} store={store} kind={page.draw.work} />) : null}
    </Framed>
  );
}

/** The section a page is in, for its breadcrumb. */
function sectionOfPage(page: NavPage): Exclude<NavSection, "overview"> {
  return (Object.keys(navPages) as NavSection[]).find((s) => navPages[s].includes(page)) as Exclude<NavSection, "overview"> ?? "agents";
}

function Framed({ title, section, children }: { title: string; section: Exclude<NavSection, "overview">; children: ComponentChildren }) {
  return (
    <section class="chat activity-page sub-app-page console" aria-label={title}>
      <header class="column-head page-head"><BackToList /><PageTitle parts={pageCrumbs(section, title)}><h1>{title}</h1></PageTitle></header>
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
      empty="No machines yet. Add one on your Mac, in Settings ▸ Machines." columns={[
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
