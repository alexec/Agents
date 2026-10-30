// The Overview (#2141): the page the control plane web page opens on. Machines and their health,
// the agents that run now, what waits for you, spend today and what happened last, each a card with
// a link to the section that has all of it. An admin's cards are the organisation's (console/fleet,
// console/live, the organisation's spend); a member's are their own machines' and sessions'.
import type { ComponentChildren } from "preact";
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { Event, FleetMachine, LiveBoard, UsageReport } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { go, type Route } from "../route";
import { hostAnswers, stateWords } from "../model/capabilities";
import { ago } from "../model/connectorSetup";
import { adminOf, fleetSummary, liveCostWords, liveStateWords, liveSummary, outOfDate } from "../model/console";
import { budgetWords } from "../model/reports";
import { cardRows, eventRows, needingYou, noEvents, noSpend, nothingRuns, overviewIntro, placeWords, placedSessions, rowsCost,
  waitingWords, workingNow, workingWords } from "../model/overview";
import { totalWords, todayTotals } from "./Activity";
import { requestCount } from "./ConsoleRecords";
import { runtimeNameIn } from "./Reports";

function Card({ title, line, children, links }: { title: string; line?: string | null; children?: ComponentChildren;
  links: [string, Route][] }) {
  return (
    <section class="overview-card" aria-label={title}>
      {/* The title on the left and where to see all of it on the right, over a hairline (#2142). */}
      <header class="overview-card-head">
        <h2>{title}</h2>
        <span class="overview-links">
          {links.map(([words, to]) => <button key={words} type="button" class="link" onClick={() => go(to)}>{words} ›</button>)}
        </span>
      </header>
      <div class="overview-card-body">
        {line && <p class="quiet">{line}</p>}
        {children}
      </div>
    </section>
  );
}

export function Overview({ store, down }: { store: Store; down: boolean }) {
  const admin = adminOf(store);
  const hosts = store.hosts.value;
  const several = hosts.length > 1;
  const fleet = useSignal<FleetMachine[] | null>(null);
  const live = useSignal<LiveBoard | null>(null);
  const spend = useSignal<UsageReport | null>(null);
  const online = hosts.filter((h) => hostAnswers(h.state)).map((h) => h.id).join(",");
  // The organisation's machines and agents for an admin, again when a machine changes and each minute.
  useEffect(() => {
    if (down || admin !== true) return;
    const load = () => {
      void store.link.call("console/fleet", {}).then((b) => { fleet.value = b.machines; }, () => { fleet.value = null; });
      void store.link.call("console/live", {}).then((b) => { live.value = b; }, () => { live.value = null; });
    };
    load();
    const every = setInterval(() => { if (document.visibilityState === "visible") load(); }, 60_000);
    return () => clearInterval(every);
  }, [down, admin, hosts]);
  // Today's spend: the organisation's for an admin, the person's own machines' for a member.
  useEffect(() => {
    if (down || admin === null) return;
    void store.link.call("reports/usage", { range: "day", scope: { kind: admin ? "org" : "me" } })
      .then((r) => { spend.value = r; }, () => { spend.value = null; });
  }, [down, admin]);
  // Each machine's events and cost, as the Events page asks for them.
  useEffect(() => {
    for (const host of hosts.filter((h) => hostAnswers(h.state))) {
      void store.loadEvents(host.id);
      void store.loadCost(host.id);
    }
  }, [online]);

  const machines: FleetMachine[] = fleet.value ?? hosts.map((host) => ({ host, ownerName: "", bot: false }) as FleetMachine);
  const version = store.plane.value?.version;
  const troubled = machines.filter((m) => !hostAnswers(m.host.state) || outOfDate(m, version));
  const placed = placedSessions(hosts, store.folders.value, (h, f) => store.folderView(h, f).headings.flatMap((x) => x.agents));
  const waiting = needingYou(placed);
  const working = workingNow(placed);
  const requests = admin === true ? requestCount(store) : null;
  const runtimeName = runtimeNameIn(store);
  const board = admin === true ? live.value : null;
  const spent = spend.value ? totalWords(rowsCost(spend.value.rows)) : totalWords(todayTotals(store.costs.value));
  const events: { host: string; event: Event }[] = Object.entries(store.events.value)
    .flatMap(([host, page]) => page.events.map((event) => ({ host, event })))
    .sort((a, b) => (b.event.lastAt ?? b.event.at) - (a.event.lastAt ?? a.event.at)).slice(0, eventRows);
  const hostName = (id: string) => hosts.find((h) => h.id === id)?.name ?? id;
  const open = (p: (typeof placed)[number]) => go({ host: p.host.id, folder: p.folder.folder.folder, session: p.agent.id });

  return (
    <section class="chat activity-page overview" aria-label="Overview" aria-busy={down}>
      <header class="column-head page-head"><div class="page-title"><h1>Overview</h1></div></header>
      <div class="scroll">
        <div class="activity-body">
          <p class="quiet">{overviewIntro}</p>
          <div class="overview-grid">
            <Card title="Machines" line={fleetSummary(machines, version)} links={[["All machines", { nav: "machines", section: "machines" }]]}>
              <ul class="overview-rows">
                {(troubled.length ? troubled : machines).slice(0, cardRows).map((m) => (
                  <li key={m.host.id}>
                    <span class={`fleet-state ${m.host.state}`}>{m.host.name}</span>
                    <span class={`quiet small${troubled.includes(m) ? " attention" : ""}`}>
                      {stateWords(m.host)}{outOfDate(m, version) ? " · out of date" : ""}
                    </span>
                  </li>
                ))}
              </ul>
            </Card>
            <Card title="Running now" line={board ? (board.agents.length ? liveSummary(board) : nothingRuns) : workingWords(working)}
              links={admin === true ? [["Live Now", { nav: "agents", section: "live" }]] : [["Agents", { nav: "agents" }]]}>
              <ul class="overview-rows">
                {board ? board.agents.slice(0, cardRows).map((a) => (
                  <li key={`${a.host}|${a.agent}`}>
                    <span>{runtimeName(a.runtime)} · {a.ownerName} · {a.hostName}</span>
                    <span class="quiet small">{liveStateWords(a)}{a.since !== undefined ? ` · ${ago(fromWireDate(a.since))}` : ""} · {liveCostWords(a.costToDate)}</span>
                  </li>
                )) : working.slice(0, cardRows).map((p) => (
                  <li key={p.agent.id}>
                    <button type="button" class="link" onClick={() => open(p)}>{p.agent.title || "Untitled session"}</button>
                    <span class="quiet small">{runtimeName(p.agent.runtimeID)} · {placeWords(p, several)}</span>
                  </li>
                ))}
              </ul>
            </Card>
            <Card title="Waiting for you" line={waitingWords(waiting.length, requests)}
              links={requests !== null ? [["Agents", { nav: "agents" }], ["Requests", { nav: "requests" }]] : [["Agents", { nav: "agents" }]]}>
              <ul class="overview-rows">
                {waiting.slice(0, cardRows).map((p) => (
                  <li key={p.agent.id}>
                    <button type="button" class="link" onClick={() => open(p)}>{p.agent.title || "Untitled session"}</button>
                    <span class="quiet small">{placeWords(p, several)}</span>
                  </li>
                ))}
              </ul>
            </Card>
            <Card title="Spend today" links={[["Spend", { nav: "reports", section: "spend" }]]}>
              {spent ? <p class="overview-figure">{spent}</p> : <p class="quiet">{noSpend}</p>}
              <p class="quiet small">{spend.value?.scope?.kind === "org" ? "The organisation" : "Your machines"}</p>
              {spend.value?.budgetUSD !== undefined && spend.value.monthSpentUSD !== undefined && (
                <p class="small">{budgetWords(spend.value.monthSpentUSD, spend.value.budgetUSD)}</p>
              )}
            </Card>
            <Card title="Recent activity" line={events.length ? null : noEvents} links={[["Events", { nav: "reports", section: "events" }]]}>
              <ul class="overview-rows">
                {events.map(({ host, event }) => (
                  <li key={`${host}|${event.position}`}>
                    <span>{event.sentence}</span>
                    <span class="quiet small">{several ? `${hostName(host)} · ` : ""}{ago(fromWireDate(event.lastAt ?? event.at))}</span>
                  </li>
                ))}
              </ul>
            </Card>
          </div>
        </div>
      </div>
    </section>
  );
}
