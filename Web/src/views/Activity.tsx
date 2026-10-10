// Activity at the top of the sidebar (#151), as the window's (#145): Events, Resources, Runtimes
// and Spending, each a row that says what it has at a glance and opens its page in the chat's
// place. What each page lets you change is the Mac's, but for marking a runtime available and
// stopping a wait (#541).
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { AllowanceState, Consequence, ControlHost, CostState, Event, ProjectSummary, RuntimeAvailability, RuntimeStatus } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import type { ActivityPage } from "../route";
import { HostedMCP, Resources } from "./Resources";
import { BackToList } from "./BackToList";
import { Modal } from "./Modal";
import { folderKey, projectFolder } from "../model/groups";
import { runtimeTally } from "../model/runtimes";
import { refusalMessage } from "../model/workflows";

function navigate(destination: { host: string; project: string; session?: string; workflow?: string }): void {
  const parts = ["h", destination.host, "p", destination.project];
  if (destination.session) parts.push("s", destination.session);
  else if (destination.workflow) parts.push("w", destination.workflow);
  location.hash = "#/" + parts.map(encodeURIComponent).join("/");
}

/** "14:05", twenty-four hours, as the window's Events row says it. */
function clock(date: Date): string {
  return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}

/** An amount in its currency, as the window's Spending says it. */
export function money(amount: number, currency: string): string {
  try {
    return new Intl.NumberFormat(undefined, { style: "currency", currency }).format(amount);
  } catch {
    return `${amount.toFixed(2)} ${currency}`;
  }
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
  const daily = state?.limits.daily;
  if (!state || !daily || daily.amount <= 0) return false;
  return (state.today[daily.currency] ?? 0) / daily.amount >= 0.85;
}

export function dayLimitReached(state: CostState | undefined): boolean {
  const daily = state?.limits.daily;
  return !!daily && daily.amount > 0 && (state?.today[daily.currency] ?? 0) >= daily.amount;
}

/** All time, folded from the projects' cost ledgers as Spending does on the other clients. */
export function lifetimeTotals(projects: ProjectSummary[]): Record<string, number> {
  const total: Record<string, number> = {};
  for (const project of projects) for (const [currency, amount] of Object.entries(project.costToDate)) {
    total[currency] = (total[currency] ?? 0) + amount;
  }
  return total;
}

function allowanceLine(state: AllowanceState): string {
  if ("available" in state.status) return "Available";
  if ("rateLimited" in state.status) return `Rate limited · trying again at ${runtimeTime(state.status.rateLimited.until)}`;
  const out = state.status.out;
  return out.until ? `Out · reset ${runtimeTime(out.until)}${out.retryAfter ? ` · checking after ${runtimeTime(out.retryAfter)}` : ""}`
    : `Out since ${runtimeTime(state.since)}${out.retryAfter ? ` · checking after ${runtimeTime(out.retryAfter)}` : ""}`;
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

const runtimeTime = (wire: number) => fromWireDate(wire as never).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });

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

const onlineHosts = (store: Store): ControlHost[] => store.hosts.value.filter((h) => h.state === "online");

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
const activityIcons: Record<ActivityPage, string> = { events: "☰\uFE0E", resources: "◫", runtimes: "⚙\uFE0E", spending: "$" };

export function ActivityRows({ store, chosen, onPick }: {
  store: Store; chosen: ActivityPage | undefined; onPick: (page: ActivityPage) => void;
}) {
  useActivity(store);
  const last = lastEvent(store);
  const resources = Object.values(store.leases.value).flatMap((s) => s.resources);
  const held = resources.reduce((n, r) => n + (r.holds ?? (r.lease ? [r.lease] : [])).length, 0);
  const waiting = resources.reduce((n, r) => n + r.line.length, 0);
  const tally = runtimeTally(Object.values(store.runtimes.value).flat());
  const costs = store.costs.value;
  const today = totalWords(todayTotals(costs));
  const mac = costs["mac"];
  const left = headroom(mac);
  // The page's name in the projects' type, after its icon in the accent, as the window's rows
  // have it (#155, #495).
  const row = (page: ActivityPage, title: string, help: string, detail: preact.ComponentChildren) => (
    <button class={`row activity-row${chosen === page ? " chosen" : ""}`} aria-current={chosen === page} title={help}
      onClick={() => onPick(page)}>
      <span class="activity-icon" aria-hidden="true">{activityIcons[page]}</span>
      <span class="title">{title}</span>
      <span class="detail">{detail}</span>
    </button>
  );
  return (
    <>
      {row("events", "Events", "What happened, what came of it, and who is waiting", last && `Last ${clock(last)}`)}
      {row("resources", "Resources", "Who holds the simulators, browsers and screen, and who is waiting",
        held + waiting > 0 && `${held} held · ${waiting} waiting`)}
      {row("runtimes", "Runtimes", "What each runtime can be started on right now",
        tally && (
          <span aria-label={tally.working === 0 ? `None of ${tally.total} working` : `${tally.working} of ${tally.total} working`}>
            {tally.working === 0 && <><span class="dot failure" aria-hidden="true" />{" "}</>}{tally.working}/{tally.total}
          </span>
        ))}
      {row("spending", "Cost", "What all of the work has cost, and what it cost today",
        (today || left) && (
          <span class={`spending${closeToFull(mac) && chosen !== "spending" ? " close" : ""}`}>
            {today && <span>{today}</span>}{left && <span>{left}</span>}
          </span>
        ))}
    </>
  );
}

const pageTitles: Record<ActivityPage, string> = { events: "Events", resources: "Resources", runtimes: "Runtimes", spending: "Cost" };

/** An Activity page in the chat's place. */
export function ActivityPageView({ store, page }: { store: Store; page: ActivityPage }) {
  const hosts = onlineHosts(store);
  useEffect(() => {
    for (const host of hosts) {
      if (page === "events") void store.loadEvents(host.id, 100);
      if (page === "spending") void store.loadCost(host.id);
      if (page === "runtimes") void store.loadRuntimes(host.id);
    }
  }, [page]);
  const several = store.hosts.value.length > 1;
  const hostName = (host: string) => (host === "mac" ? "This Mac" : store.hosts.value.find((h) => h.id === host)?.name ?? host);
  return (
    <section class={`chat activity-page ${page}-page`} aria-label={pageTitles[page]}>
      <header class="column-head"><BackToList /><h1>{pageTitles[page]}</h1></header>
      <div class="scroll">
        <div class="activity-body">
          {page === "events" && <EventsList store={store} hostName={hostName} />}
          {page === "resources" && (
            <>
              {store.hosts.value.map((host) => (
                <section key={host.id}>
                  {several && <h2 class="section-head">{hostName(host.id)}</h2>}
                  <Resources store={store} host={host.id} open />
                  <HostedMCP store={store} host={host.id} />
                </section>
              ))}
              {Object.values(store.leases.value).every((s) => s.resources.length === 0)
                && Object.values(store.hostedMCP.value).every((s) => s.servers.length === 0) && (
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
                  const allowance = allowanceSet?.rows.find((row) => row.credentialKey.split(":", 1)[0] === status.runtime.id);
                  const isAllowanceOut = !!allowance && "out" in allowance.state.status && !allowance.unusable;
                  const now = allowanceSet ? fromWireDate(allowanceSet.at) : new Date();
                  return <li key={status.runtime.id} class={isAllowanceOut || isOut(status) ? "out" : ""}>
                    <p><span class="strong">{status.runtime.name}</span>{" "}
                      <span class="quiet small">{allowance?.unusable ? `Not usable: ${allowance.unusable}` : allowance ? allowanceLine(allowance.state) : availabilityWords(status.availability)}{status.outdated ? " · an update is out" : ""}</span></p>
                    {allowance && !allowance.unusable && allowanceReading(allowance.state, now) && <p class="quiet small">{allowanceReading(allowance.state, now)}</p>}
                    {status.poolNote && <p class="quiet small">{status.poolNote}</p>}
                    {isAllowanceOut && allowance && <button onClick={() => void store.markRuntimeAvailable(host.id, allowance.credentialKey)}>Mark available</button>}
                  </li>
                })}
              </ul>
            </section>
          ))}
          {page === "runtimes" && <p class="hint">Installing and signing in are managed on the Mac, in Settings ▸ Agent Runtimes.</p>}
          {page === "spending" && <SpendingPage store={store} hostName={hostName} />}
        </div>
      </div>
    </section>
  );
}

/**
 * Where Events reads from (#541), as the other clients' one menu has it: "all", "mac" (an event
 * about a host itself), or one host's project as `host|folderKey`.
 */
export function eventIsIn(where: string, host: string, event: Event): boolean {
  if (where === "all") return true;
  if ("mac" in event.scope) return where === "mac";
  return where === `${host}|${folderKey(event.scope.project._0)}`;
}

/** Everything one event carries, in the rows the window's detail and the Remote's sheet show. */
export function eventDetailRows(event: Event, scopeName: string): [string, string][] {
  const rows: [string, string][] = [
    ["When", fromWireDate(event.at).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "medium" })],
    ["Where", scopeName],
  ];
  if (event.count > 1 && event.lastAt !== undefined) rows.push(["Repeats", `${event.count} times, last at ${clock(fromWireDate(event.lastAt))}`]);
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
    const folder = event.scope.project._0;
    return (store.projects.value[host] ?? []).find((project) => folderKey(project.project.folder) === folderKey(folder))?.name
      ?? decodeURIComponent(folder.split("/").pop() ?? "Project");
  };
  const places = store.hosts.value.flatMap((host) => (store.projects.value[host.id] ?? [])
    .filter((project) => !project.project.archivedAt)
    .map((project) => ({ value: `${host.id}|${folderKey(project.project.folder)}`, name: several ? `${hostName(host.id)}: ${project.name}` : project.name })))
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
    if (agent) navigate({ host, project: projectFolder(agent), session: id });
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
              <button class="event-waiting" onClick={() => navigate({ host, project: w.folder, session: w.agentID })}>
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
          <option value="all">All projects</option>
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
    const openWorkflow = () => navigate({ host, project: item.folder, workflow: item.workflowID });
    return <span class="quiet small event-consequence">↳ Fired <button class="link" onClick={openWorkflow}>{item.workflowID}</button>{item.agentID && <> · <button class="link" onClick={() => openAgent(host, item.agentID!)}>{store.agent(host, item.agentID)?.title ?? "Open agent"}</button></>}</span>;
  }
  const item = consequence.refused;
  const openWorkflow = () => navigate({ host, project: item.folder, workflow: item.workflowID });
  // Put off, not refused (#422): what comes of it later takes this line's place.
  const verb = "queued" in item.reason ? "Queued for" : "Refused by";
  return <span class="quiet small event-consequence">↳ {verb} <button class="link" onClick={openWorkflow}>{item.workflowID}</button> — {refusalMessage(item.reason)}</span>;
}

function SpendingPage({ store, hostName }: { store: Store; hostName: (host: string) => string }) {
  const projects = Object.values(store.projects.value).flat();
  const totals = lifetimeTotals(projects);
  const currencies = Object.keys(totals).sort();
  const unmeasured = projects.reduce((count, project) => count + project.unmeasuredAgents, 0);
  const costs = Object.entries(store.costs.value);
  const today = totalWords(todayTotals(store.costs.value));
  return (
    <>
      <p class="spending-today"><span class="quiet">All time</span> <span class="strong">{totalWords(totals) ?? "Nothing has been spent yet"}</span></p>
      {currencies.map((currency) => (
        <section key={currency}>
          {currencies.length > 1 && <h2 class="section-head">{currency}</h2>}
          {projects.filter((project) => project.costToDate[currency] !== undefined)
            .sort((a, b) => (b.costToDate[currency] ?? 0) - (a.costToDate[currency] ?? 0) || a.name.localeCompare(b.name))
            .map((project) => (
              <p key={project.project.folder}>
                {project.name}{project.project.archivedAt ? <span class="quiet small"> · Archived</span> : ""}
                <span class="detail">{money(project.costToDate[currency] ?? 0, currency)}</span>
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
          {state.limits.daily && <p class={`quiet small${closeToFull(state) ? " close" : ""}`}>
            Daily limit {money(state.limits.daily.amount, state.limits.daily.currency)} · {headroom(state)}{dayLimitReached(state) && " · Nothing new will start until tomorrow"}</p>}
          {state.limits.perAgent && <p class="quiet small">
            Each agent up to {money(state.limits.perAgent.amount, state.limits.perAgent.currency)}</p>}
          {state.note && <p class="quiet small">⚠︎ {state.note}</p>}
        </section>
      ))}
      <p class="hint">Limits are set on the Mac.</p>
    </>
  );
}
