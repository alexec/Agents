// Activity at the top of the sidebar (#151), as the window's (#145): Events, Resources, Runtimes
// and Spending, each a row that says what it has at a glance and opens its page in the chat's
// place. The pages are read-only: what each page lets you change is the Mac's.
import { useEffect } from "preact/hooks";
import type { Store } from "../model/store";
import type { ControlHost, CostState, Event, RuntimeAvailability, RuntimeStatus } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import type { ActivityPage } from "../route";
import { Resources } from "./Resources";

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
  return (state.today[daily.currency] ?? 0) / daily.amount >= 0.8;
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

export function ActivityRows({ store, chosen, onPick }: {
  store: Store; chosen: ActivityPage | undefined; onPick: (page: ActivityPage) => void;
}) {
  useActivity(store);
  const last = lastEvent(store);
  const resources = Object.values(store.leases.value).flatMap((s) => s.resources);
  const held = resources.reduce((n, r) => n + (r.holds ?? (r.lease ? [r.lease] : [])).length, 0);
  const waiting = resources.reduce((n, r) => n + r.line.length, 0);
  const out = Object.values(store.runtimes.value).flat().filter(isOut).length;
  const costs = store.costs.value;
  const today = totalWords(todayTotals(costs));
  const mac = costs["mac"];
  const left = headroom(mac);
  // The page's name in the projects' type, with no glyph, as the window's rows have it (#155).
  const row = (page: ActivityPage, title: string, help: string, detail: preact.ComponentChildren) => (
    <button class={`row activity-row${chosen === page ? " chosen" : ""}`} aria-current={chosen === page} title={help}
      onClick={() => onPick(page)}>
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
        out > 0 && <><span class="dot failure" aria-hidden="true" /> {out} out</>)}
      {row("spending", today ? "Today" : "Spending", today ? "What every agent has cost today. Opens Spending." : "What all of the work has cost",
        (today || left) && (
          <span class={`spending${closeToFull(mac) && chosen !== "spending" ? " close" : ""}`}>
            {today && <span>{today}</span>}{left && <span>{left}</span>}
          </span>
        ))}
    </>
  );
}

const pageTitles: Record<ActivityPage, string> = { events: "Events", resources: "Resources", runtimes: "Runtimes", spending: "Spending" };

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
      <header class="column-head"><h1>{pageTitles[page]}</h1></header>
      <div class="scroll">
        <div class="activity-body">
          {page === "events" && <EventsList store={store} hostName={several ? hostName : null} />}
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
                {(store.runtimes.value[host.id] ?? []).map((status) => (
                  <li key={status.runtime.id} class={isOut(status) ? "out" : ""}>
                    <p><span class="strong">{status.runtime.name}</span>{" "}
                      <span class="quiet small">{availabilityWords(status.availability)}{status.outdated ? " · an update is out" : ""}</span></p>
                    {status.poolNote && <p class="quiet small">{status.poolNote}</p>}
                  </li>
                ))}
              </ul>
            </section>
          ))}
          {page === "runtimes" && <p class="hint">Installing, signing in and allowances are the Mac’s, in Settings ▸ Agent Runtimes.</p>}
          {page === "spending" && <SpendingPage store={store} hostName={hostName} />}
        </div>
      </div>
    </section>
  );
}

function EventsList({ store, hostName }: { store: Store; hostName: ((host: string) => string) | null }) {
  const events: { host: string; event: Event }[] = Object.entries(store.events.value)
    .flatMap(([host, page]) => page.events.map((event) => ({ host, event })))
    .sort((a, b) => (b.event.lastAt ?? b.event.at) - (a.event.lastAt ?? a.event.at));
  const waiting = Object.entries(store.events.value).flatMap(([host, page]) => page.waiting.map((w) => ({ host, w })));
  return (
    <>
      {waiting.length > 0 && (
        <section>
          <h2 class="section-head">Waiting</h2>
          <ul class="event-list">
            {waiting.map(({ host, w }) => <li key={`${host}|${w.agentID}`}><span class="strong">{w.title}</span></li>)}
          </ul>
        </section>
      )}
      <h2 class="section-head">What happened</h2>
      {events.length === 0 && <p class="hint">Nothing yet.</p>}
      <ul class="event-list">
        {events.map(({ host, event }) => {
          const at = fromWireDate(event.lastAt ?? event.at);
          return (
            <li key={`${host}|${event.position}`}>
              <time class="when" dateTime={at.toISOString()} title={at.toLocaleString()}>{clock(at)}</time>
              <span class="body">
                <span>{event.sentence}{event.count > 1 && <span class="quiet"> ×{event.count}</span>}</span>
                {(event.publisher || hostName) && (
                  <span class="quiet small">{[event.publisher && `by “${event.publisher.title}”`, hostName?.(host)].filter(Boolean).join(" · ")}</span>
                )}
                {event.message && <span class="quiet small">{event.message}</span>}
              </span>
            </li>
          );
        })}
      </ul>
    </>
  );
}

function SpendingPage({ store, hostName }: { store: Store; hostName: (host: string) => string }) {
  const costs = Object.entries(store.costs.value);
  const today = totalWords(todayTotals(store.costs.value));
  return (
    <>
      <p class="spending-today"><span class="quiet">Today</span> <span class="strong">{today ?? money(0, "USD")}</span></p>
      {costs.map(([host, state]) => (
        <section key={host}>
          <h2 class="section-head">{hostName(host)}</h2>
          <p>{totalWords(state.today) ?? "Nothing spent today"}</p>
          {state.limits.daily && <p class={`quiet small${closeToFull(state) ? " close" : ""}`}>
            Daily limit {money(state.limits.daily.amount, state.limits.daily.currency)} · {headroom(state)}</p>}
          {state.limits.perAgent && <p class="quiet small">
            Each agent up to {money(state.limits.perAgent.amount, state.limits.perAgent.currency)}</p>}
        </section>
      ))}
      <p class="hint">Limits are set on the Mac.</p>
    </>
  );
}
