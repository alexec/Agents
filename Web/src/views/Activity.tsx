// Activity at the top of the sidebar (#151), as the window's (#145): Events, Resources, Runtimes,
// MCP Servers (#589), Worktrees (#790) and Spending, each a row whose tooltip says what it has at a glance (#587)
// and that opens its page in the chat's place. What each page lets you change is the Mac's, but
// for marking a runtime available and stopping a wait (#541).
import { Fragment } from "preact";
import { useEffect, useState } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { AccountProfile, AllowanceReading, AllowanceState, Consequence, ControlMachine, CostState, Event, FolderSummary, RuntimeAvailability, RuntimeStatus } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { who } from "../model/audit";
import type { ActivityPage } from "../route";
import { Resources } from "./Resources";
import { MCPServersList } from "./MCPServers";
import { YourConnections } from "./ConnectorSetup";
import { WorktreesList } from "./Worktrees";
import { AuditPane } from "./Audit";
import { ReportsPane } from "./Reports";
import { forCleanup, pageLine, rowWords, tally as worktreeTally, worktreesIntro } from "../model/worktrees";
import { BackToList } from "./BackToList";
import { Modal } from "./Modal";
import { folderKey, folderPath } from "../model/groups";
import { accountChoices, accountRows, accountState, agentsHolding, allowanceLine, defaultAccountName, isOrgRow, orgAllowanceLine, ownRow, ownSignInID, reachesFoot, reachesTheModelBy, removeMessage, rowTitle, runtimeTally, runtimeTime, signInOnTheMac } from "../model/runtimes";
import { fromOrganisation } from "../model/orgAccounts";
import { setBy as setByWords } from "../model/orgPolicy";
import { healthTally, personalEmpty, personalIntro, personalServers } from "../model/hostedMCP";
import { refusalMessage } from "../model/workflows";
import { describe } from "../model/errors";
import { dayTokenLimitReached, money } from "../model/limits";
import { UsageCharts } from "./UsageCharts";
import { mergeUsage } from "../model/usage";
import { hostAnswers, hostNeedsUpdate } from "../model/capabilities";
import { mergeTime } from "../model/time";
import { TimeCharts } from "./TimeCharts";
import { MilestonesSection, TimeMilestonesUnder } from "./Milestones";
import { isComplete } from "../model/milestones";
import { Capability } from "../protocol/capabilities.generated";
import { OrgBudget, OrgPolicyLine, PassThroughList } from "./OrgPolicyLine";
import { PageTitle } from "./TopBar";
import { pageCrumbs, sectionOfActivity } from "../model/crumbs";

function navigate(destination: { host: string; folder: string; session?: string; workflow?: string }): void {
  const parts = ["h", destination.host, "p", destination.folder];
  if (destination.session) parts.push("s", destination.session);
  else if (destination.workflow) parts.push("w", destination.workflow);
  location.hash = "#/" + parts.map(encodeURIComponent).join("/");
}

/** "14:05", twenty-four hours, as the window's Events row says it. */
function clock(date: Date): string {
  return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}

/** Every host's day, added up by currency: what the work cost is the question, not where. */
export function todayTotals(costs: Record<string, CostState>): Record<string, number> {
  const total: Record<string, number> = {};
  for (const state of Object.values(costs)) {
    for (const [currency, amount] of Object.entries(state.today)) total[currency] = (total[currency] ?? 0) + amount;
  }
  return total;
}

/** "£1.20", or "£1.20 + $0.40": two currencies read as two numbers. */
export function totalWords(total: Record<string, number>): string | null {
  const parts = Object.entries(total).sort(([a], [b]) => a.localeCompare(b)).map(([currency, amount]) => money(amount, currency));
  return parts.length ? parts.join(" + ") : null;
}

/** What is left of this Mac's daily limit, if it has one (CostState.dayHeadroom). */
export function headroom(state: CostState | undefined): string | null {
  const daily = state?.limits.daily;
  if (!state || !daily) return null;
  return `${money(Math.max(0, daily.amount - (state.today[daily.currency] ?? 0)), daily.currency)} left`;
}

/** Close enough to the daily limit to say so in colour (CostState.dayIsCloseToFull). */
export function closeToFull(state: CostState | undefined): boolean {
  return spendCloseToFull(state) || tokensCloseToFull(state);
}

/** Close to the daily token limit (CostState.dayTokensAreCloseToFull): Tokens' row warns (#956). */
export function tokensCloseToFull(state: CostState | undefined): boolean {
  const tokens = state?.limits.dailyTokens;
  return !!state && tokens !== undefined && tokens > 0 && (state.tokensToday ?? 0) / tokens >= 0.85;
}

/** Close to the daily money limit (CostState.daySpendIsCloseToFull): Cost's row warns (#956). */
export function spendCloseToFull(state: CostState | undefined): boolean {
  const daily = state?.limits.daily;
  if (!state || !daily || daily.amount <= 0) return false;
  return (state.today[daily.currency] ?? 0) / daily.amount >= 0.85;
}

export function dayLimitReached(state: CostState | undefined): boolean {
  if (dayTokenLimitReached(state)) return true;
  const daily = state?.limits.daily;
  return !!daily && daily.amount > 0 && (state?.today[daily.currency] ?? 0) >= daily.amount;
}

/** All time, folded from the folders' cost ledgers as Spending does on the other clients. */
export function lifetimeTotals(folders: FolderSummary[]): Record<string, number> {
  const total: Record<string, number> = {};
  for (const folder of folders) for (const [currency, amount] of Object.entries(folder.costToDate)) {
    total[currency] = (total[currency] ?? 0) + amount;
  }
  return total;
}

function allowanceReading(state: AllowanceState, now: Date): string | null {
  const reading = state.reading;
  if (!reading || (reading.resetsAt && fromWireDate(reading.resetsAt).getTime() <= now.getTime())) return null;
  const left = reading.spent ? 0 : reading.used == null ? null : Math.round((1 - reading.used) * 100);
  const text = left === null ? (reading.nearlySpent ? "Nearly used up" : reading.window ?? "")
    : left === 0 ? "None left" : `${left}% left`;
  if (!text) return null;
  return [text, reading.resetsAt && `resets ${runtimeTime(reading.resetsAt)}`, `as of ${runtimeTime(reading.at)}`].filter(Boolean).join(" · ");
}

/**
 * How much of the plan window is used, as a bar under the reading's words (#1097): only when
 * the reading has an amount, full when spent. Red when spent, orange when nearly spent. The
 * words above say the same, so it is hidden from screen readers.
 */
function AllowanceBar({ reading }: { reading: AllowanceReading }) {
  const used = reading.spent ? 1 : reading.used;
  if (used == null) return null;
  const tone = reading.spent || used >= 1 ? " spent" : reading.nearlySpent || used >= 0.8 ? " nearly-spent" : "";
  return <div class={`allowance-bar${tone}`} aria-hidden="true"><span style={{ width: `${Math.round(used * 100)}%` }} /></div>;
}

/**
 * Reaches the Model By (#999, FR-024), on the runtime's row: the account new sessions use. A choice
 * the organisation's policy refuses is shown, dimmed, with its line, and cannot be chosen.
 */
function ReachesTheModelBy({ store, host, runtime }: { store: Store; host: string; runtime: string }) {
  const [problem, setProblem] = useState<string>();
  const choices = accountChoices(runtime, store.accountProfiles.value[host] ?? [], store.policyStates.value[host]?.policy);
  if (!choices.shows) return null;
  const current = choices.defaultAccount?.id ?? ownSignInID;
  const refused = (id: string) => (id === ownSignInID ? choices.ownSetBy : choices.accounts.find((a) => a.id === id)?.setBy);
  const set = (id: string) => {
    setProblem(undefined);
    store.setDefaultAccount(host, runtime, id).catch((e: unknown) => setProblem(describe(e)));
  };
  return <div class="reaches-by">
    <label>{reachesTheModelBy}{" "}
      <select value={current} onChange={(e) => set((e.target as HTMLSelectElement).value)}>
        <option value={ownSignInID} disabled={!!choices.ownSetBy}>{defaultAccountName}{choices.ownSetBy ? ` (${setByWords})` : ""}</option>
        {choices.accounts.map((a) => <option key={a.id} value={a.id} disabled={!!a.setBy}>{a.name}{a.setBy ? ` (${setByWords})` : ""}</option>)}
      </select>
    </label>
    <OrgPolicyLine mark={refused(current)} />
    <p class={problem ? "failure small" : "quiet small"}>{problem ?? reachesFoot}</p>
  </div>;
}

/** Add Account on a runtime that keeps its sign-in in a folder (#840): a name, then Add. */
function AddAccount({ store, host, runtime }: { store: Store; host: string; runtime: string }) {
  const [name, setName] = useState<string | null>(null);
  const [problem, setProblem] = useState<string>();
  if (name === null) return <button onClick={() => { setName(""); setProblem(undefined); }}>Add Account…</button>;
  const add = () => {
    store.addAccount(host, runtime, name).then(() => setName(null), (e: unknown) => setProblem(describe(e)));
  };
  return <form class="add-account" onSubmit={(e) => { e.preventDefault(); add(); }}>
    <input aria-label="Account name" placeholder="Name, such as Work" value={name} onInput={(e) => setName((e.target as HTMLInputElement).value)} />
    <button type="submit" disabled={name.trim() === ""}>Add</button>
    <button type="button" onClick={() => setName(null)}>Cancel</button>
    {problem && <p class="quiet small failure">{problem}</p>}
  </form>;
}

/**
 * Remove on an added account (#840): asked first, with how many sessions it stops and that it
 * can't be undone (#2264), and the host's refusal under it.
 */
function RemoveAccount({ store, host, account, place }: { store: Store; host: string; account: AccountProfile; place: string }) {
  const [problem, setProblem] = useState<string>();
  const remove = () => {
    const stopping = agentsHolding(store.agents.value[host] ?? [], account).length;
    if (!window.confirm(`Remove ${account.name}? ${removeMessage(stopping, place)}`)) return;
    setProblem(undefined);
    store.removeAccount(host, account).catch((e: unknown) => setProblem(describe(e)));
  };
  return <>
    <button onClick={remove}>Remove…</button>
    {problem && <p class="quiet small failure">{problem}</p>}
  </>;
}

/**
 * Whether the pool has left a runtime, or one of its models, out (#140): what the window's row
 * counts as out. One that isn't installed here was never in, and isn't counted.
 */
export function isOut(status: RuntimeStatus): boolean {
  return status.poolNote !== undefined;
}

export function availabilityWords(availability: RuntimeAvailability): string {
  if ("available" in availability) return "Available";
  if ("missing" in availability) return "Not installed";
  if ("needsSignIn" in availability) return "Needs signing in";
  if ("failed" in availability) return `Can't start: ${availability.failed.reason}`;
  if ("installing" in availability) return availability.installing.progress ?? "Installing…";
  return `Install failed: ${availability.installFailed.reason}`;
}

/** The newest event on any host. */
function lastEvent(store: Store): Date | null {
  const times = Object.values(store.events.value).flatMap((page) => page.events.map((e) => e.lastAt ?? e.at));
  return times.length ? fromWireDate(Math.max(...times) as never) : null;
}

const onlineHosts = (store: Store): ControlMachine[] => store.hosts.value.filter((h) => hostAnswers(h.state));

/** Asks each host for its events and its day again: on connecting, and every minute after. */
function useActivity(store: Store): void {
  const online = onlineHosts(store).map((h) => h.id).join(",");
  useEffect(() => {
    const load = () => {
      for (const host of onlineHosts(store)) {
        void store.loadEvents(host.id);
        void store.loadCost(host.id);
      }
    };
    load();
    const every = setInterval(() => { if (document.visibilityState === "visible") load(); }, 60_000);
    return () => clearInterval(every);
  }, [online]);
}

/** Each Activity page's icon, the window's SF Symbol as near as text has it (#495). */
const activityIcons: Record<ActivityPage, string> = { events: "☰\uFE0E", resources: "◫", runtimes: "⚙\uFE0E", mcp: "▤", worktrees: "⑂", spending: "$", tokens: "#", time: "◷", milestones: "✓" };

/** The rows of one of the sidebar's two groups (#915): Status, what goes on now, or Usage, the past. */
export function ActivityRows({ group, store, chosen, onPick }: {
  group: "status" | "usage"; store: Store; chosen: ActivityPage | undefined; onPick: (page: ActivityPage) => void;
}) {
  useActivity(store);
  const last = lastEvent(store);
  const resources = Object.values(store.leases.value).flatMap((s) => s.resources);
  const held = resources.reduce((n, r) => n + (r.holds ?? (r.lease ? [r.lease] : [])).length, 0);
  const waiting = resources.reduce((n, r) => n + r.line.length, 0);
  const tally = runtimeTally(Object.values(store.runtimes.value).flat());
  const mcp = healthTally(store.hosts.value.flatMap((host) => personalServers(store.mcpHealthOf(host.id))));
  const worktrees = rowWords(worktreeTally(store.hosts.value.flatMap((host) =>
    forCleanup(store.worktreeLists.value[host.id] ?? [], store.worktreeSizes.value[host.id]).flatMap((g) => g.worktrees))));
  const costs = store.costs.value;
  const today = totalWords(todayTotals(costs));
  const mac = costs[store.macHostID.value];
  const milestones = store.milestones.value[milestonesHost(store) ?? ""];
  const left = headroom(mac);
  // The page's name in the folders' type, after its icon in the accent, as the window's rows
  // have it (#155, #495). Nothing at its end, which is only a session's (#587): what it would say
  // at a glance is its tooltip's, and the icon turns red when the page has something wrong to say.
  const row = (page: ActivityPage, title: string, help: string, figures: string | null, warns = false) => (
    <button class={`row activity-row${chosen === page ? " chosen" : ""}`} aria-current={chosen === page}
      title={figures ? `${figures}. ${help}` : help} aria-description={figures ?? undefined} onClick={() => onPick(page)}>
      <span class={`activity-icon${warns ? " warns" : ""}`} aria-hidden="true">{activityIcons[page]}</span>
      <span class="title">{title}</span>
    </button>
  );
  const spent = [today && `${today} today`, left].filter(Boolean).join(", ");
  const tokensLeft = mac?.limits.dailyTokens !== undefined
    ? `${Math.max(0, mac.limits.dailyTokens - (mac.tokensToday ?? 0)).toLocaleString()} left` : null;
  const tokens = mac ? [`${(mac.tokensToday ?? 0).toLocaleString()} tokens today`, tokensLeft].filter(Boolean).join(", ") : null;
  if (group === "usage") return (
    <>
      {row("spending", "Cost", "What all of the work has cost, and what it cost today", spent || null,
        spendCloseToFull(mac))}
      {row("tokens", "Tokens", "What the work used in tokens, and the token limits", tokens, tokensCloseToFull(mac))}
      {row("time", "Time", "Where the time of running chats went: the agent, its tools, and waiting", null)}
      {/* The newcomer's checklist (#1067), only while a milestone is still to earn, as an empty
          smart group hides (#507). Then the list is under Time's charts. */}
      {milestones && !isComplete(milestones)
        && row("milestones", "Milestones", "The first steps taken in Agents, and the ones still to take", null)}
    </>
  );
  return (
    <>
      {row("events", "Events", "What happened, what came of it, and who is waiting", last && `Last at ${clock(last)}`)}
      {row("resources", "Resources", "Who holds the simulators, browsers and screen, and who is waiting",
        held + waiting > 0 ? `${held} held, ${waiting} waiting` : null)}
      {row("runtimes", "Runtimes", "What each runtime can be started on right now",
        tally ? (tally.working === 0 ? `None of ${tally.total} working` : `${tally.working} of ${tally.total} working`) : null,
        tally?.working === 0)}
      {row("mcp", "Connectors", "Every connector in your own mcp.json, and how each is doing",
        mcp?.words ?? null, mcp?.failing ?? false)}
      {row("worktrees", "Worktrees", "Every folder's worktrees, and how much each holds", worktrees)}
    </>
  );
}

const pageTitles: Record<ActivityPage, string> = { events: "Events", resources: "Resources", runtimes: "Runtimes", mcp: "Connectors", worktrees: "Worktrees", spending: "Cost", tokens: "Tokens", time: "Time", milestones: "Milestones" };

/** An Activity page in the chat's place. */
export function ActivityPageView({ store, page }: { store: Store; page: ActivityPage }) {
  const hosts = onlineHosts(store);
  useEffect(() => {
    for (const host of hosts) {
      if (page === "events") void store.loadEvents(host.id, 100);
      if (page === "spending" || page === "tokens") void store.loadCost(host.id);
      if (page === "spending" || page === "tokens") void store.loadRuntimes(host.id);
      if (page === "runtimes") void store.loadRuntimes(host.id);
    }
  }, [page]);
  const several = store.hosts.value.length > 1;
  const hostName = (host: string) => (store.isMac(host) ? "This Mac" : store.hosts.value.find((h) => h.id === host)?.name ?? host);
  // Events, or Audit: who did what through the control plane (#996).
  const pane = useSignal<"events" | "audit">("events");
  // Cost, or Reports: every person's machines, from the control plane (#1811).
  const costPane = useSignal<"cost" | "reports">("cost");
  return (
    <section class={`chat activity-page ${page}-page`} aria-label={pageTitles[page]}>
      <header class="column-head page-head"><BackToList />
        <PageTitle parts={sectionOfActivity(page) ? pageCrumbs(sectionOfActivity(page)!, pageTitles[page]) : []}><h1>{pageTitles[page]}</h1></PageTitle>
      </header>
      <div class="scroll">
        <div class="activity-body">
          {page === "events" && (
            <div class="tabs events-panes" role="tablist" aria-label="Show">
              {(["events", "audit"] as const).map((p) => (
                <button key={p} role="tab" aria-selected={pane.value === p} class={pane.value === p ? "on" : ""}
                  onClick={() => { pane.value = p; }}>{p === "events" ? "Events" : "Audit"}</button>
              ))}
            </div>
          )}
          {page === "events" && pane.value === "events" && <EventsList store={store} hostName={hostName} />}
          {page === "events" && pane.value === "audit" && <AuditPane store={store} hostName={hostName} />}
          {page === "resources" && (
            <>
              {store.hosts.value.map((host) => (
                <section key={host.id}>
                  {several && <h2 class="section-head">{hostName(host.id)}</h2>}
                  <Resources store={store} host={host.id} open />
                </section>
              ))}
              {Object.values(store.leases.value).every((s) => s.resources.length === 0) && (
                <p class="hint">Nothing is declared or held. Resources are declared on the Mac, in Settings ▸ Resources.</p>
              )}
            </>
          )}
          {page === "runtimes" && store.hosts.value.map((host) => (
            <section key={host.id}>
              {several && <h2 class="section-head">{hostName(host.id)}</h2>}
              <ul class="runtime-list">
                {(store.runtimes.value[host.id] ?? []).map((status) => {
                  const allowanceSet = store.runtimeAllowances.value[host.id];
                  const allowance = allowanceSet && ownRow(allowanceSet.rows, status.runtime.id);
                  const isAllowanceOut = !!allowance && "out" in allowance.state.status && !allowance.unusable;
                  const now = allowanceSet ? fromWireDate(allowanceSet.at) : new Date();
                  return <Fragment key={status.runtime.id}>
                    <li class={isAllowanceOut || isOut(status) ? "out" : ""}>
                      <p class={status.setBy ? "set-by-org" : undefined}><span class="strong">{status.runtime.name}</span>{" "}
                        <span class="quiet small">{allowance?.unusable ? `Not usable: ${allowance.unusable}` : allowance ? allowanceLine(allowance.state) : availabilityWords(status.availability)}{status.outdated ? " · an update is out" : ""}</span></p>
                      {allowance && !allowance.unusable && allowanceReading(allowance.state, now) && <>
                        <p class="quiet small">{allowanceReading(allowance.state, now)}</p>
                        {allowance.state.reading && <AllowanceBar reading={allowance.state.reading} />}
                      </>}
                      {/* A runtime the organisation does not allow here: shown, with why (#998). */}
                      <OrgPolicyLine mark={status.setBy} />
                      {status.poolNote && <p class="quiet small">{status.poolNote}</p>}
                      {allowance?.setupNote && <p class="quiet small">{allowance.setupNote.split("`").map((part, i) => i % 2 ? <code key={i}>{part}</code> : part)}</p>}
                      {isAllowanceOut && allowance && <button onClick={() => void store.markRuntimeAvailable(host.id, allowance.credentialKey)}>Mark available</button>}
                      {/* Only this Mac's, and only one that is on it: no client can sign in a server's account (#2257). */}
                      {status.runtime.accountFolderVariable !== undefined && !("missing" in status.availability) && store.isMac(host.id) && <AddAccount store={store} host={host.id} runtime={status.runtime.id} />}
                      <ReachesTheModelBy store={store} host={host.id} runtime={status.runtime.id} />
                    </li>
                    {/* Each account added to it (#840), then the organisation's (#999), under it, with its own allowance. */}
                    {allowanceSet && accountRows(allowanceSet.rows, status.runtime.id).map((row) => {
                      const out = "out" in row.state.status && !row.unusable;
                      const org = isOrgRow(row);
                      // An org account is the organisation's to remove (#999).
                      const account = org ? undefined : store.addedAccounts(host.id, status.runtime.id).find((a) => a.id === row.accountID);
                      return <li key={row.credentialKey} class={out ? "out" : ""}>
                        <p><span class="strong">{rowTitle(row, status.runtime.name)}</span>{" "}
                          <span class="quiet small">{row.unusable ? `Not usable: ${row.unusable}`
                            : org ? orgAllowanceLine(row.state, row.tokensToday, now, runtimeTime, allowanceLine) : allowanceLine(row.state)}</span></p>
                        {/* Where it is from, never a key or an address (FR-023, FR-026). */}
                        {org && <p class="quiet small">{fromOrganisation}</p>}
                        {account?.signedInAs !== undefined && <p class="quiet small">{accountState(account)}</p>}
                        {!row.unusable && allowanceReading(row.state, now) && <>
                          <p class="quiet small">{allowanceReading(row.state, now)}</p>
                          {row.state.reading && <AllowanceBar reading={row.state.reading} />}
                        </>}
                        {account && !account.signedIn && store.isMac(host.id) && <p class="quiet small">{signInOnTheMac}</p>}
                        {out && <button onClick={() => void store.markRuntimeAvailable(host.id, row.credentialKey)}>Mark available</button>}
                        {account && <RemoveAccount store={store} host={host.id} account={account}
                          place={store.isMac(host.id) ? "the Mac" : hostName(host.id)} />}
                      </li>;
                    })}
                  </Fragment>;
                })}
              </ul>
              {/* The person's own pass-through names, a name the policy refuses dimmed (#998). */}
              <PassThroughList names={store.passThrough.value[host.id] ?? []} />
            </section>
          ))}
          {page === "mcp" && (
            <>
              <p class="hint">{personalIntro}</p>
              {store.hosts.value.map((host) => (
                <section key={host.id}>
                  {several && <h2 class="section-head">{hostName(host.id)}</h2>}
                  {store.has(host.id, Capability.connections1)
                    ? <YourConnections store={store} host={host.id} />
                    : <p class="hint">{hostNeedsUpdate}</p>}
                  <h2 class="setup-heading">User connectors</h2>
                  <MCPServersList store={store} host={host.id} />
                </section>
              ))}
              {store.hosts.value.every((host) => personalServers(store.mcpHealthOf(host.id)).length === 0) && (
                <p class="hint">{personalEmpty}</p>
              )}
            </>
          )}
          {page === "worktrees" && (
            <>
              <p class="hint">{worktreesIntro}</p>
              {store.hosts.value.map((host) => (
                <section key={host.id}>
                  {several && <h2 class="section-head">{hostName(host.id)}</h2>}
                  <p>{pageLine(worktreeTally(forCleanup(store.worktreeLists.value[host.id] ?? [],
                    store.worktreeSizes.value[host.id]).flatMap((g) => g.worktrees)))}</p>
                  <WorktreesList store={store} host={host.id} />
                </section>
              ))}
              <button onClick={() => { for (const host of hosts) void store.loadWorktrees(host.id); }}>Refresh</button>
            </>
          )}
          {page === "runtimes" && <p class="hint">Install a runtime on the Mac, in Settings ▸ Agent Runtimes. Sign it in on the Mac, in Runtimes.</p>}
          {page === "spending" && (
            <div class="tabs events-panes" role="tablist" aria-label="Show">
              {(["cost", "reports"] as const).map((p) => (
                <button key={p} role="tab" aria-selected={costPane.value === p} class={costPane.value === p ? "on" : ""}
                  onClick={() => { costPane.value = p; }}>{p === "cost" ? "Cost" : "Reports"}</button>
              ))}
            </div>
          )}
          {page === "spending" && costPane.value === "cost" && <SpendingPage store={store} hostName={hostName} />}
          {page === "spending" && costPane.value === "reports" && <ReportsPane store={store} runtimeName={chartRuntimeName(store, chartHosts(store))} />}
          {page === "tokens" && <TokensPage store={store} hostName={hostName} />}
          {page === "time" && <TimePage store={store} />}
          {page === "milestones" && <MilestonesPage store={store} />}
        </div>
      </div>
    </section>
  );
}

/**
 * Where Events reads from (#541), as the other clients' one menu has it: "all", "mac" (an event
 * about a host itself), or one host's folder as `host|folderKey`.
 */
export function eventIsIn(where: string, host: string, event: Event): boolean {
  if (where === "all") return true;
  if ("mac" in event.scope) return where === "mac";
  return where === `${host}|${folderKey(event.scope.folder._0)}`;
}

/** Everything one event carries, in the rows the window's detail and the Remote's sheet show. */
export function eventDetailRows(event: Event, scopeName: string): [string, string][] {
  const rows: [string, string][] = [
    ["When", fromWireDate(event.at).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "medium" })],
    ["Where", scopeName],
  ];
  if (event.count > 1 && event.lastAt !== undefined) rows.push(["Repeats", `${event.count} times, last at ${clock(fromWireDate(event.lastAt))}`]);
  if (event.actor) rows.push(["By", who(event.actor)]);
  if (event.publisher) rows.push(["Published by", event.publisher.title]);
  if (event.message) rows.push(["Message", event.message]);
  for (const key of Object.keys(event.details).sort()) rows.push([key, event.details[key]!]);
  rows.push(["Position", String(event.position)]);
  return rows;
}

function EventsList({ store, hostName }: { store: Store; hostName: (host: string) => string }) {
  const where = useSignal("all");
  const picked = useSignal<{ host: string; event: Event; scope: string } | null>(null);
  const several = store.hosts.value.length > 1;
  const scopeName = (host: string, event: Event) => {
    if ("mac" in event.scope) return "This Mac";
    const folder = event.scope.folder._0;
    return (store.folders.value[host] ?? []).find((candidate) => folderKey(candidate.folder.folder) === folderKey(folder))?.name
      ?? decodeURIComponent(folder.split("/").pop() ?? "Folder");
  };
  const places = store.hosts.value.flatMap((host) => (store.folders.value[host.id] ?? [])
    .filter((folder) => !folder.folder.archivedAt)
    .map((folder) => ({ value: `${host.id}|${folderKey(folder.folder.folder)}`, name: several ? `${hostName(host.id)}: ${folder.name}` : folder.name })))
    .sort((a, b) => a.name.localeCompare(b.name));
  const events: { host: string; event: Event }[] = Object.entries(store.events.value)
    .flatMap(([host, page]) => page.events.filter((event) => eventIsIn(where.value, host, event)).map((event) => ({ host, event })))
    .sort((a, b) => (b.event.lastAt ?? b.event.at) - (a.event.lastAt ?? a.event.at));
  const waiting = Object.entries(store.events.value).flatMap(([host, page]) => page.waiting.map((w) => ({ host, w })));
  const days = new Map<string, { title: string; items: { host: string; event: Event }[] }>();
  for (const item of events) {
    const date = fromWireDate(item.event.lastAt ?? item.event.at);
    const key = `${date.getFullYear()}-${date.getMonth()}-${date.getDate()}`;
    let day = days.get(key);
    if (!day) {
      const today = new Date();
      const yesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1);
      const same = (a: Date, b: Date) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
      day = { title: same(date, today) ? "Today" : same(date, yesterday) ? "Yesterday" : date.toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" }), items: [] };
      days.set(key, day);
    }
    day.items.push(item);
  }
  const openAgent = async (host: string, id: string) => {
    const agent = await store.loadEventAgent(host, id);
    if (agent) navigate({ host, folder: folderPath(agent), session: id });
  };
  const showOlder = () => { for (const [host, page] of Object.entries(store.events.value)) if (page.hasMore) void store.loadOlderEvents(host); };
  const hasOlder = Object.values(store.events.value).some((page) => page.hasMore);
  const shown = picked.value;
  return (
    <>
      {waiting.length > 0 && (
        <section>
          <h2 class="section-head">Waiting now</h2>
          <ul class="event-list waiting-list">
            {waiting.map(({ host, w }) => <li key={`${host}|${w.agentID}`}>
              <button class="event-waiting" onClick={() => navigate({ host, folder: w.folder, session: w.agentID })}>
                <span class="strong">{w.title}</span><span class="quiet small">{w.status.line}</span>
              </button>
              {w.status.cancellable && <button class="event-stop" aria-label={`Stop ${w.title} waiting`}
                title="Stop waiting. Nothing will start it again for this wait."
                onClick={() => void store.cancelWait(host, w.agentID)}>✕</button>}
            </li>)}
          </ul>
        </section>
      )}
      <div class="event-head">
        <h2 class="section-head">What happened</h2>
        <select aria-label="Where" value={where.value} onChange={(e) => (where.value = (e.currentTarget as HTMLSelectElement).value)}>
          <option value="all">All folders</option>
          <option value="mac">This Mac</option>
          {places.map((place) => <option key={place.value} value={place.value}>{place.name}</option>)}
        </select>
      </div>
      {events.length === 0 && <p class="hint">{where.value === "all" ? "Nothing yet." : "Nothing has happened there yet."}</p>}
      {[...days.entries()].map(([key, day]) => <section key={key}>
        <h3 class="event-day">{day.title}</h3>
        <ul class="event-list">{day.items.map(({ host, event }) => {
          const at = fromWireDate(event.at);
          const scope = scopeName(host, event);
          const open = () => (picked.value = { host, event, scope: hostName(host) !== scope && several ? `${scope} · ${hostName(host)}` : scope });
          return <li key={`${host}|${event.position}`}>
            <time class="when" dateTime={at.toISOString()} title={at.toLocaleString()}>{clock(at)}</time>
            <span class="body">
              <button class="event-open" title="Everything this event carries" onClick={open}>
                {event.sentence}{event.count > 1 && <span class="quiet"> ×{event.count}</span>}
              </button>
              <span class="quiet small event-name">{event.name} · {scope}{hostName(host) !== scope && ` · ${hostName(host)}`}</span>
              {event.publisher && <span class="quiet small">by “{event.publisher.title}”</span>}
              {event.message && <span class="quiet small">“{event.message}”</span>}
              {event.consequences.map((consequence, index) => <ConsequenceLine key={index} consequence={consequence} host={host} store={store} openAgent={openAgent} />)}
            </span>
          </li>;
        })}</ul>
      </section>)}
      {hasOlder && <button class="link event-older" onClick={showOlder}>Show older</button>}
      {shown && <EventDetail key={`${shown.host}|${shown.event.position}`} event={shown.event} scope={shown.scope} close={() => (picked.value = null)} />}
    </>
  );
}

/** One event, read-only: the window's detail and the Remote's sheet. Copy as trigger stays the Mac's. */
function EventDetail({ event, scope, close }: { event: Event; scope: string; close: () => void }) {
  return (
    <Modal label="Event" close={close}>
      <form method="dialog" class="sheet-body event-detail">
        <h2>{event.sentence}</h2>
        <p class="quiet small event-name">{event.name}</p>
        <dl>{eventDetailRows(event, scope).map(([name, value], index) => <div key={index}><dt>{name}</dt><dd>{value}</dd></div>)}</dl>
        <div class="sheet-actions"><button value="close">Done</button></div>
      </form>
    </Modal>
  );
}

function ConsequenceLine({ consequence, host, store, openAgent }: {
  consequence: Consequence; host: string; store: Store; openAgent: (host: string, id: string) => void;
}) {
  if ("woke" in consequence) return <span class="quiet small event-consequence">↳ Woke <button class="link" onClick={() => openAgent(host, consequence.woke.agentID)}>{consequence.woke.title}</button></span>;
  if ("couldNotWake" in consequence) return <span class="quiet small event-consequence">↳ Could not wake {consequence.couldNotWake.title} — {consequence.couldNotWake.reason}</span>;
  if ("fired" in consequence) {
    const item = consequence.fired;
    const openWorkflow = () => navigate({ host, folder: item.folder, workflow: item.workflowID });
    return <span class="quiet small event-consequence">↳ Fired <button class="link" onClick={openWorkflow}>{item.workflowID}</button>{item.agentID && <> · <button class="link" onClick={() => openAgent(host, item.agentID!)}>{store.agent(host, item.agentID)?.title ?? "Open agent"}</button></>}</span>;
  }
  const item = consequence.refused;
  const openWorkflow = () => navigate({ host, folder: item.folder, workflow: item.workflowID });
  // Put off, not refused (#422): what comes of it later takes this line's place.
  const verb = "queued" in item.reason ? "Queued for" : "Refused by";
  return <span class="quiet small event-consequence">↳ {verb} <button class="link" onClick={openWorkflow}>{item.workflowID}</button> — {refusalMessage(item.reason)}</span>;
}

/**
 * The hosts the charts add up (#1267): This Mac first, whose recap the Time page keeps, then every
 * other online host, each moved into this browser's days.
 */
function chartHosts(store: Store): string[] {
  const online = store.hosts.value.filter((h) => hostAnswers(h.state) && h.relay === undefined).map((h) => h.id);
  const ids = online.length > 0 ? online : store.hosts.value.map((h) => h.id);
  const macID = store.macHostID.value;
  return [...ids.filter((id) => id === macID), ...ids.filter((id) => id !== macID)];
}

/** A runtime's name, from the first host that knows it. */
function chartRuntimeName(store: Store, hosts: readonly string[]) {
  return (id: string) => hosts.map((host) => store.runtimes.value[host]?.find((s) => s.runtime.id === id)?.runtime.name)
    .find((name) => name) || id;
}

/** Where the time of running chats went (#852): every host's, as on the window and the Remote (#1267). */
function TimePage({ store }: { store: Store }) {
  const hosts = chartHosts(store);
  const host = hosts[0];
  useEffect(() => {
    for (const each of hosts) {
      void store.loadTime(each);
      void store.loadRuntimes(each);
    }
    const every = setInterval(() => {
      if (document.visibilityState === "visible") for (const each of hosts) void store.loadTime(each);
    }, 60_000);
    return () => clearInterval(every);
  }, [hosts.join(" ")]);
  const runtimeName = chartRuntimeName(store, hosts);
  if (!host) return <p class="quiet">No machine is connected.</p>;
  const history = store.time.value[host] ? mergeTime(hosts.flatMap((each) => store.time.value[each] ?? [])) : undefined;
  return (
    <TimeMilestonesUnder milestones={store.milestones.value[host]}>
      <TimeCharts history={history} runtimeName={runtimeName} />
    </TimeMilestonesUnder>
  );
}

/** The host whose milestones are drawn: this Mac's, as on the window and the Remote. */
function milestonesHost(store: Store): string | undefined {
  const macID = store.macHostID.value;
  return store.hosts.value.some((h) => h.id === macID) ? macID : store.hosts.value[0]?.id;
}

/** The milestones as a page (#1067): the newcomer's checklist, from its row in Usage. */
function MilestonesPage({ store }: { store: Store }) {
  const milestones = store.milestones.value[milestonesHost(store) ?? ""];
  if (!milestones) return <p class="quiet">No machine is connected.</p>;
  return <MilestonesSection milestones={milestones} />;
}

/** What the work used in tokens (#956): the charts in tokens, then each host's day against its token limits. */
function TokensPage({ store, hostName }: { store: Store; hostName: (host: string) => string }) {
  const hosts = chartHosts(store);
  const costs = hosts.map((host) => store.costs.value[host]);
  useEffect(() => { for (const host of hosts) void store.loadUsage(host); }, [hosts.join(" "), ...costs]);
  const runtimeName = chartRuntimeName(store, hosts);
  const history = mergeUsage(hosts.flatMap((host) => store.usage.value[host] ?? []));
  return (
    <>
      {hosts.length > 0 && <UsageCharts metric="tokens" history={history} runtimeName={runtimeName} />}
      {Object.entries(store.costs.value).map(([host, state]) => (
        <section key={host}>
          <h2 class="section-head">{hostName(host)}</h2>
          <p>{(state.tokensToday ?? 0).toLocaleString()} tokens today</p>
          {state.limits.dailyTokens !== undefined && <p class={`quiet small${tokensCloseToFull(state) ? " close" : ""}`}>
            Daily token limit {state.limits.dailyTokens.toLocaleString()} · {Math.max(0, state.limits.dailyTokens - (state.tokensToday ?? 0)).toLocaleString()} left{dayTokenLimitReached(state) && " · Nothing new will start until tomorrow"}</p>}
          {state.limits.perAgentTokens !== undefined && <p class="quiet small">
            Each agent up to {state.limits.perAgentTokens.toLocaleString()} tokens</p>}
        </section>
      ))}
      <p class="hint">Limits are set on the Mac.</p>
    </>
  );
}

function SpendingPage({ store, hostName }: { store: Store; hostName: (host: string) => string }) {
  const folders = Object.values(store.folders.value).flat();
  const totals = lifetimeTotals(folders);
  const currencies = Object.keys(totals).sort();
  const unmeasured = folders.reduce((count, folder) => count + folder.unmeasuredAgents, 0);
  const costs = Object.entries(store.costs.value);
  const today = totalWords(todayTotals(store.costs.value));
  // The charts are every host's, in this browser's days, as on the window and the Remote (#1267).
  const hosts = chartHosts(store);
  const chartCosts = hosts.map((host) => store.costs.value[host]);
  useEffect(() => { for (const host of hosts) void store.loadUsage(host); }, [hosts.join(" "), ...chartCosts]);
  const runtimeName = chartRuntimeName(store, hosts);
  const history = mergeUsage(hosts.flatMap((host) => store.usage.value[host] ?? []));
  return (
    <>
      {hosts.length > 0 && <UsageCharts metric="cost" history={history} runtimeName={runtimeName} />}
      <p class="spending-today"><span class="quiet">All time</span> <span class="strong">{totalWords(totals) ?? "Nothing has been spent yet"}</span></p>
      {currencies.map((currency) => (
        <section key={currency}>
          {currencies.length > 1 && <h2 class="section-head">{currency}</h2>}
          {folders.filter((folder) => folder.costToDate[currency] !== undefined)
            .sort((a, b) => (b.costToDate[currency] ?? 0) - (a.costToDate[currency] ?? 0) || a.name.localeCompare(b.name))
            .map((folder) => (
              <p key={folder.folder.folder}>
                {folder.name}{folder.folder.archivedAt ? <span class="quiet small"> · Archived</span> : ""}
                <span class="detail">{money(folder.costToDate[currency] ?? 0, currency)}</span>
              </p>
            ))}
        </section>
      ))}
      {unmeasured > 0 && <p class="quiet small">At least this much: {unmeasured} {unmeasured === 1 ? "chat" : "chats"} ran on a runtime that reported no price.</p>}
      <h2 class="section-head">Today</h2>
      <p class="spending-today"><span class="strong">{today ?? money(0, "USD")}</span></p>
      {costs.map(([host, state]) => (
        <section key={host}>
          <h2 class="section-head">{hostName(host)}</h2>
          <p>{totalWords(state.today) ?? "Nothing spent today"}</p>
          {state.limits.daily && <p class={`quiet small${spendCloseToFull(state) ? " close" : ""}`}>
            Daily limit {money(state.limits.daily.amount, state.limits.daily.currency)} · {headroom(state)}{dayLimitReached(state) && " · Nothing new will start until tomorrow"}</p>}
          {state.limits.perAgent && <p class="quiet small">
            Each agent up to {money(state.limits.perAgent.amount, state.limits.perAgent.currency)}</p>}
          {/* The organisation's budgets, beside these: the lower is used (#998). */}
          <OrgBudget state={state} />
          {state.note && <p class="quiet small">⚠︎ {state.note}</p>}
        </section>
      ))}
      <p class="hint">Limits are set on the Mac.</p>
    </>
  );
}
