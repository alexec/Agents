// The control plane's three apps (#1804): the switcher at the top of the page (Workspace | Console |
// Reports), and the Console and Reports drawn in place of the sidebar and the chat: a list of
// pages on the left, the page on the right. The Console is the admins'; a member sees why not.
// The control plane checks each call's role itself; the page only leaves out what would be refused.
import type { ComponentChildren } from "preact";
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import { go, route } from "../route";
import type { SubApp } from "../route";
import { CallFailed } from "../wire/link";
import { adminsOnly, appTitle, apps, consoleFoot, failedWords, fleetFilterTitle, fleetFilters, fleetFoot, fleetShown, fleetSummary, grouped,
  kindWords, noMachines, noRoles, notBuilt, openSection, outOfDate, ownerWords, runningWords, sectionsOf } from "../model/console";
import type { AppName, FleetFilter, Section } from "../model/console";
import type { FleetBoard, PolicyKept } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { ago } from "../model/connectorSetup";
import { missingWords, stateWords, versionWords } from "../model/capabilities";
import { ReportsPage, runtimeNameIn } from "./Reports";
import { BotsSection, PeopleSection } from "./People";
import { GroupsSection } from "./Groups";
import { ReportPolicyPage, policyNotSaved } from "./ConsolePolicy";
import { OrgPolicyPage, orgPolicyNotSaved } from "./ConsoleOrgPolicy";
import { ModelAccessPage } from "./ConsoleModelAccess";
import { followsWords } from "../model/orgPolicy";
import { AuditPage, RequestsPage, requestCount } from "./ConsoleRecords";
import { TeamWorkflowsPage } from "./ConsoleWorkflows";
import { LiveNowPage } from "./ConsoleLive";
import { ProjectsPage } from "./ConsoleProjects";
import { SignInPage } from "./ConsoleSignIn";
import { CataloguePage } from "./Governance";
import { ReadAPIPage } from "./ReadAPI";

/** Whether this person is an admin of the control plane, from the store's one people list (#2055): null until it answers. */
function adminOf(store: Store): boolean | null {
  const list = store.people.value;
  if (list) return list.admin;
  return store.peopleFailure.value ? false : null;
}

/** Why the role is not known: a control plane before roles (#994), or none to ask. */
function roleProblemOf(store: Store): string | null {
  const failure = store.peopleFailure.value;
  return failure instanceof CallFailed && failure.code === -32601 ? noRoles : null;
}

/** Workspace | Console | Reports, at the top of every page. Console is left out for a member. */
export function AppSwitcher({ store }: { store: Store; down: boolean }) {
  const current: AppName = route.value.app ?? "workspace";
  const shown = apps.filter((a) => a !== "console" || adminOf(store) || current === "console");
  return (
    <nav class="app-switcher" aria-label="Apps">
      <div class="segmented" role="tablist">
        {shown.map((a) => (
          <button key={a} role="tab" aria-selected={current === a} class={current === a ? "on" : ""}
            onClick={() => go(a === "workspace" ? {} : { app: a })}>{appTitle[a]}</button>
        ))}
      </div>
    </nav>
  );
}

/** The Console or Reports: its pages on the left, the one open on the right. */
export function SubAppPage({ store, app, down }: { store: Store; app: SubApp; down: boolean }) {
  const open = openSection(app, route.value.section);
  const isAdmin = adminOf(store);
  const gated = app === "console" && isAdmin !== true;
  return (
    <div class="columns sub-app" aria-busy={down}>
      <nav class="folders sub-app-list" aria-label={appTitle[app]}>
        {grouped(sectionsOf(app)).map(([group, list]) => (
          <div key={group} class="sub-app-group">
            <h2 class="section-head">{group}</h2>
            {list.map((s) => (
              <button key={s.id} type="button" class={`sub-app-row${s.id === open.id ? " on" : ""}`} disabled={!s.built || gated}
                aria-current={s.id === open.id ? "page" : undefined} title={s.built ? s.about : notBuilt}
                onClick={() => go({ app, section: s.id })}>
                {s.title}
                {s.id === "requests" && !gated && requestCount(store) > 0 && <span class="sub-app-count">{requestCount(store)}</span>}
                {s.id === "reportPolicy" && !gated && policyNotSaved(store) && <span class="quiet small attention">Not saved</span>}
                {s.id === "policy" && !gated && orgPolicyNotSaved(store) && <span class="quiet small attention">Not saved</span>}
              </button>
            ))}
          </div>
        ))}
      </nav>
      <section class="chat activity-page sub-app-page" aria-label={open.title}>
        <header class="column-head"><h1>{open.title}</h1></header>
        <div class="scroll">
          <div class="activity-body settings-body">
            {gated
              ? <p class="hint">{isAdmin === null ? "Loading…" : roleProblemOf(store) ?? adminsOnly}</p>
              : app === "console" ? <ConsoleSection store={store} section={open} down={down} />
              : <ReportsPage store={store} section={open} down={down} />}
          </div>
        </div>
      </section>
    </div>
  );
}

function ConsoleSection({ store, section, down }: { store: Store; section: Section; down: boolean }) {
  switch (section.id) {
    case "people": return <PeoplePage store={store} down={down} />;
    case "machines": return <MachinesPage store={store} down={down} />;
    case "projects": return <ProjectsPage store={store} down={down} />;
    case "signIn": return <SignInPage store={store} down={down} />;
    case "live": return <LiveNowPage store={store} down={down} runtimeName={runtimeNameIn(store)} />;
    case "policy": return <OrgPolicyPage store={store} down={down} />;
    case "modelAccess": return <ModelAccessPage store={store} down={down} />;
    case "reportPolicy": return <ReportPolicyPage store={store} down={down} />;
    case "requests": return <RequestsPage store={store} down={down} />;
    case "workflows": return <TeamWorkflowsPage store={store} down={down} />;
    case "catalogue": return <CataloguePage store={store} down={down} />;
    case "readApi": return <ReadAPIPage store={store} down={down} />;
    case "audit": return <AuditPage store={store} down={down} />;
    default: return <Overview store={store} />;
  }
}

/** M2: who belongs, their roles and machines, bots and groups. The same sections as Settings ▸ People, Bots and Groups (#2132). */
function PeoplePage({ store, down }: { store: Store; down: boolean }) {
  return (
    <>
      <PeopleSection store={store} down={down} />
      {/* The bots apart from the people, as Settings has them (#2132). */}
      <BotsSection store={store} down={down} />
      <GroupsSection store={store} down={down} />
    </>
  );
}

/** M1: every machine on the control plane, its owner, state, version and running agents. */
function MachinesPage({ store, down }: { store: Store; down: boolean }) {
  const board = useSignal<FleetBoard | null>(null);
  // The policy and each machine's applied version (#998, FR-024); none from a control plane before it.
  const policy = useSignal<PolicyKept | null>(null);
  const problem = useSignal<string | null>(null);
  const filter = useSignal<FleetFilter>("all");
  const load = async () => {
    try {
      const [fleet, kept] = await Promise.all([store.link.call("console/fleet", {}), store.link.call("policy/get", {}).catch(() => null)]);
      board.value = fleet;
      policy.value = kept;
      problem.value = null;
    } catch (error) {
      problem.value = failedWords(error);
    }
  };
  // Again when a machine joins, leaves or changes state, when the policy changes, and each minute for the running counts.
  const hosts = store.hosts.value;
  const orgPolicy = store.orgPolicy.value;
  useEffect(() => { if (!down) void load(); }, [down, hosts, orgPolicy]);
  useEffect(() => {
    const every = setInterval(() => { if (document.visibilityState === "visible" && !down) void load(); }, 60_000);
    return () => clearInterval(every);
  }, [down]);
  const version = store.plane.value?.version;
  const all = board.value?.machines ?? [];
  const shown = fleetShown(all, filter.value, version);
  return (
    <div class="fleet">
      {problem.value && <p class="hint">{problem.value}</p>}
      {!board.value && !problem.value && <p class="hint">Loading…</p>}
      {board.value && (
        <>
          <p class="quiet small">{fleetSummary(all, version)}</p>
          <div class="segmented" role="radiogroup" aria-label="Show">
            {fleetFilters.map((f) => (
              <button key={f} role="radio" aria-checked={filter.value === f} class={filter.value === f ? "on" : ""}
                onClick={() => { filter.value = f; }}>{fleetFilterTitle[f]} {fleetShown(all, f, version).length}</button>
            ))}
          </div>
          {all.length === 0 ? <p class="hint">{noMachines}</p> : (
            <table class="console-table">
              <thead>
                <tr><th>Machine</th><th>Owner</th><th>State</th><th>Version</th><th class="num">Running</th><th>Last listed</th></tr>
              </thead>
              <tbody>
                {shown.map((m) => {
                  const missing = missingWords(m.host, version);
                  return (
                    <tr key={m.host.id}>
                      <td><span class="strong">{m.host.name}</span><br /><span class="quiet small">{kindWords(m)}</span></td>
                      <td>{ownerWords(m)}</td>
                      <td><span class={`fleet-state ${m.host.state}`}>{stateWords(m.host)}</span></td>
                      <td title={missing ?? undefined}>
                        {versionWords(m.host)}
                        {outOfDate(m, version) && <><br /><span class="small attention">Out of date</span></>}
                        {followsWords(m, policy.value?.policy, policy.value?.machines) !== null && (
                          <><br /><span class={`small${m.host.capabilities?.includes("host.policy/1") ? " quiet" : " attention"}`}>
                            {followsWords(m, policy.value?.policy, policy.value?.machines)}</span></>
                        )}
                      </td>
                      <td class="num">{runningWords(m)}</td>
                      <td class="quiet">{m.heardAt === undefined ? "—" : ago(fromWireDate(m.heardAt))}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          )}
          <p class="hint">{fleetFoot}</p>
        </>
      )}
    </div>
  );
}

/** The Console's first page: each of its pages, what it is for, and which are still to come. */
function Overview({ store }: { store: Store }) {
  const waiting = requestCount(store);
  return (
    <>
      <ul class="console-cards">
        {sectionsOf("console").filter((s) => s.id !== "overview").map((s) => (
          <Card key={s.id} section={s} count={s.id === "requests" ? waiting : 0}>
            {s.built
              ? <button type="button" class="link" onClick={() => go({ app: "console", section: s.id })}>Open</button>
              : <span class="quiet small">{notBuilt}</span>}
          </Card>
        ))}
      </ul>
      <p class="hint">{consoleFoot}</p>
    </>
  );
}

function Card({ section, count, children }: { section: Section; count: number; children: ComponentChildren }) {
  return (
    <li class="console-card">
      <span class="strong">{section.title}{count > 0 && <span class="sub-app-count">{count}</span>}</span>
      <span class="quiet small">{section.about}</span>
      {children}
    </li>
  );
}
