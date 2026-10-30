// The pages that were the Console's (#1804), each in its section since #2141 (model/nav.ts): People,
// Machines, Projects, Sign-In, Live Now, Policy, Model Access, Report Policy, Requests, Team Workflows,
// Catalogue, Read API and Audit. They are the admins'; a member who opens one sees why not. The
// control plane checks each call's role itself; the page only leaves out what would be refused.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import { CallFailed } from "../wire/link";
import { failedWords, fleetFilterTitle, fleetFilters, fleetFoot, fleetShown, fleetSummary,
  kindWords, noMachines, noRoles, outOfDate, ownerWords, runningWords } from "../model/console";
import type { FleetFilter } from "../model/console";
import type { FleetBoard, PolicyKept } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { ago } from "../model/connectorSetup";
import { missingWords, stateWords, versionWords } from "../model/capabilities";
import { runtimeNameIn } from "./Reports";
import { BotsSection, PeopleSection } from "./People";
import { GroupsSection } from "./Groups";
import { ReportPolicyPage } from "./ConsolePolicy";
import { OrgPolicyPage } from "./ConsoleOrgPolicy";
import { ModelAccessPage } from "./ConsoleModelAccess";
import { followsWords } from "../model/orgPolicy";
import { AuditPage, RequestsPage } from "./ConsoleRecords";
import { TeamWorkflowsPage } from "./ConsoleWorkflows";
import { LiveNowPage } from "./ConsoleLive";
import { ProjectsPage } from "./ConsoleProjects";
import { SignInPage } from "./ConsoleSignIn";
import { CataloguePage } from "./Governance";
import { ReadAPIPage } from "./ReadAPI";

/** Why the role is not known: a control plane before roles (#994), or none to ask. */
export function roleProblemOf(store: Store): string | null {
  const failure = store.peopleFailure.value;
  return failure instanceof CallFailed && failure.code === -32601 ? noRoles : null;
}

/** A page of what was the Console (#1804), by its id, in its section since #2141. */
export function ConsoleSection({ store, id, down }: { store: Store; id: string; down: boolean }) {
  switch (id) {
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
    default: return null;
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
export function MachinesPage({ store, down }: { store: Store; down: boolean }) {
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
