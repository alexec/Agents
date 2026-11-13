// Work ▸ Features (#3269, spec 3265), as the window's WorkFeaturesPane, in the Work look (#4418) and as a delivery view
// (#4589, specs/4328-work-look/features-delivery.md): Board ▾ (#3282, Mac + web) and Refresh in the page's bar; then the
// groups (#4115) Needs you, In flight, Idle and Finished (folded, #3741), each head with its count. A feature (forge/features
// on each machine) is two lines: its colour, title and label chip; its epics, what is in flight and, in Needs you, what
// waits; at the end a bar of its children done, in flight and not started. A feature in Needs you or In flight starts open:
// each open epic is a line with where it is in its plan (forge/plan), its bar and its lead, then its children in flight
// (from the sessions labelled with them) and the rest in words; then its issues with no epic that are in flight. Under 700 px
// the chip and the bars' words go, an epic's where and lead go on its second line, a child's words on its second line, and
// an epic shows at most two children.
import { effect, signal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import { keepWork, keptWorkRead } from "../model/localCopy";
import type { Agent, ForgeFeature, ForgeItem, ForgePlan } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import { boardChoices, boardName, errorWords, labelColor, noForgeHere, shortRef, withBoard } from "../model/work";
import { ErrorStrip, FromDeviceStrip, LabelChip, PlaceholderRows, RefreshButton, StateIcon } from "./WorkParts";
import { boardHosts, boards, forgeHosts, listHosts, loadBoards } from "../model/workLists";
import { Choice } from "./Work";
import {
  type Delivery, type FeatureGroup, type InFlight, addDelivery, deliveryShares, deliveryWords, epicLead, epicsDone, epicsDoneWords,
  featureFlight, featureFlightWords, featureGroups, featureSessions, featureTitle, flightOrder, flightShown, flightShownPhone, groupWords,
  inFlight, leadRowWords, mergeFeatures, needsWords, noFeatures, noFeaturesLabel, noFeaturesTitle, nothingInFlight, nothingOpen,
  openEpicWords, openedFeature, planDelivery, progressDelivery, readingWords, restWords, sessionWords, startsOpen, updatedWords, whereWords,
} from "../model/workFeatures";
import { go, routeHash } from "../route";
import { ForgeTitle } from "../render/ForgeTitle";

// The list's state lives for the tab, so Back from an epic's page finds it as it was left.
const features = signal<ForgeFeature[] | null>(null);
/** The open pull requests labelled needs-approval, of every machine (#4115). */
const approvals = signal<string[]>([]);
const errors = signal<string[]>([]);
/** The features a person opened (true) or folded (false), until the page is read again (note 3). */
const featureOpen = signal<Readonly<Record<string, boolean>>>({});
/** The groups a person opened or closed (#3741, #4115). Each is open until closed, except Finished,
 * which is closed until opened, unless every feature is in it. */
const groupOpen = signal<Readonly<Partial<Record<FeatureGroup, boolean>>>>({});
/** Each feature's open issues (forge/issues), with the machine that read each. */
const items = signal<Readonly<Record<string, { items: { host: string; item: ForgeItem }[]; errors: string[] }>>>({});
/** Each epic's plan (forge/plan), by its ref; a string when the read failed. */
const plans = signal<Readonly<Record<string, ForgePlan | string>>>({});
const planning = new Set<string>();
/** The features whose issues were asked for, so an open feature asks once. */
const itemReads = new Set<string>();
const asked = signal(0);
/** Whether a read of the features runs, for Refresh's spin. */
const reading = signal(false);
/** The board chosen, by its url; empty for all. */
const board = signal("");
let read: string | undefined;
/** The features on screen came from this device's copy (#4930), until the machines answer. */
const fromDevice = signal(false);
/** When the copy on screen was read from the machines (#5142), for the strip's "Last update" line. */
const copyAt = signal<number | undefined>(undefined);
/** The board the features on screen were read for: the copy is drawn only for another. */
let shownFor: string | undefined;
/** The machines answered for `shownFor`: what is on screen is theirs, and is kept as it fills in. */
let answered = false;

/** Work ▸ Features as this device keeps it (#4930). */
interface KeptFeatures {
  features: ForgeFeature[]; approvals: string[];
  items: Record<string, { items: { host: string; item: ForgeItem }[]; errors: string[] }>; plans: Record<string, ForgePlan>;
}

// Kept a second after the features, their issues and their plans last changed, while every read answered (#4930).
let keepTimer: ReturnType<typeof setTimeout> | undefined;
effect(() => {
  const list = features.value;
  void items.value;
  void plans.value;
  if (keepTimer) clearTimeout(keepTimer);
  if (!list || !answered || fromDevice.value || errors.value.length > 0) return;
  const on = shownFor ?? "";
  keepTimer = setTimeout(() => {
    if (!answered || shownFor !== on || errors.peek().length > 0) return;
    const fine = Object.fromEntries(Object.entries(items.peek()).filter(([, v]) => v.errors.length === 0));
    const read = Object.fromEntries(Object.entries(plans.peek()).filter((e): e is [string, ForgePlan] => typeof e[1] !== "string"));
    keepWork("features", on, { features: features.peek() ?? [], approvals: approvals.peek(), items: fine, plans: read } satisfies KeptFeatures);
  }, 1_000);
});

async function loadFeatures(store: Store) {
  const mine = asked.value;
  const on = board.value;
  const hosts = listHosts(store, on);
  const key = `${mine} ${on} ${hosts.map((h) => h.id).join(",")}`;
  if (read === key && features.value !== null) return;
  read = key;
  reading.value = true;
  // The features on screen stay until the machines answer (#4930); a board not shown yet draws this device's copy.
  if (shownFor !== on) {
    const got = await keptWorkRead<KeptFeatures>("features", on);
    const kept = got?.value;
    if (got && kept && asked.value === mine && board.value === on && shownFor !== on) {
      copyAt.value = got.at;
      features.value = kept.features;
      approvals.value = kept.approvals;
      errors.value = [];
      items.value = kept.items;
      plans.value = kept.plans;
      shownFor = on;
      answered = false;
      fromDevice.value = true;
    } else if (shownFor !== on) {
      features.value = null;
    }
  }
  const got = await Promise.all(hosts.map(async (h) => {
    try {
      return { host: h, list: await store.link.call("forge/features", withBoard({}, on), h.id) };
    } catch (e) {
      return { host: h, list: { features: [], errors: [{ forge: "", message: describe(e) }] } };
    }
  }));
  if (asked.value !== mine || board.value !== on) return;
  reading.value = false;
  approvals.value = [];
  items.value = {};
  plans.value = {};
  planning.clear();
  itemReads.clear();
  featureOpen.value = {};
  shownFor = on;
  answered = true;
  fromDevice.value = false;
  errors.value = got.flatMap(({ host, list }) => (list.errors ?? []).map((e) => errorWords(e, hosts.length > 1 ? host.name : undefined)));
  features.value = mergeFeatures(got.map(({ list }) => list.features));
  approvals.value = got.flatMap(({ list }) => list.approvals ?? []);
  // Every feature's issues at once, so a bar and its epics draw without a click; Finished has no open issue.
  for (const f of features.value) if (f.open > 0 || (f.issues ?? 1) > 0) void readItems(store, f.name);
}

/** An opened feature's open issues from every machine. */
async function readItems(store: Store, name: string) {
  itemReads.add(name.toLowerCase());
  const mine = asked.value;
  const on = board.value;
  const hosts = listHosts(store, on);
  const got = await Promise.all(hosts.map(async (h) => {
    const machine = hosts.length > 1 ? h.name : undefined;
    try {
      const list = await store.link.call("forge/issues", withBoard({ state: "open", limit: 100, feature: name }, on), h.id);
      return { items: list.items.map((item) => ({ host: h.id, item })), errors: (list.errors ?? []).map((e) => errorWords(e, machine)) };
    } catch (e) {
      return { items: [], errors: [machine ? `${machine}: ${describe(e)}` : describe(e)] };
    }
  }));
  if (asked.value !== mine || board.value !== on) return;
  items.value = { ...items.value, [name.toLowerCase()]: { items: got.flatMap((g) => g.items), errors: got.flatMap((g) => g.errors) } };
}

/** An open feature's epics' plans, each read once until the page is read again (note 16: until work/features, #4586). */
function readPlans(store: Store, epics: readonly { host: string; item: ForgeItem }[]) {
  const mine = asked.value;
  for (const { host, item } of epics) {
    const ref = item.node.ref;
    if (planning.has(ref)) continue;
    planning.add(ref);
    void store.link.call("forge/plan", { node: item.node }, host).then((p): ForgePlan | string => p, (e) => describe(e)).then((got) => {
      if (asked.value === mine) plans.value = { ...plans.value, [ref]: got };
    });
  }
}

function toggle(name: string, isOpen: boolean) {
  featureOpen.value = { ...featureOpen.value, [name.toLowerCase()]: !isOpen };
}

export function WorkFeatures({ store }: { store: Store }) {
  const hosts = forgeHosts(store);
  useEffect(() => { void loadFeatures(store); }, [asked.value, board.value, listHosts(store, board.value).map((h) => h.id).join(",")]);
  const boardKey = boardHosts(store).map((h) => h.id).join(",");
  useEffect(() => { void loadBoards(store); }, [boardKey]);
  const list = features.value;
  const refresh = () => { asked.value++; void loadBoards(store, true); };
  return (
    <div class="work-list work-features">
      {/* The page's bar (Features notes 6 and 7): Board ▾ at its trailing end (Mac + web), then Refresh. */}
      <div class="work-features-bar">
        <Choice label="Board" any="All boards" value={board.value} options={boardChoices(boards.value, board.value)}
          words={(url) => boardName(boards.value, url)} onChange={(url) => { board.value = url; }} />
        <RefreshButton busy={reading.value && list === null && hosts.length > 0} onClick={refresh} />
      </div>
      {hosts.length === 0 ? (
        <div class="work-empty">
          <StackGlyph />
          <p class="strong">Connect a forge to see features</p>
          <p class="quiet">{noForgeHere}</p>
          <button type="button" onClick={() => go({ nav: "settings", section: "mcp" })}>Settings ▸ Connectors</button>
        </div>
      ) : list === null ? <PlaceholderRows count={5} />
        : list.length === 0 && errors.value.length === 0 ? (
          <div class="work-empty">
            <StackGlyph />
            <p class="strong">{noFeaturesTitle}</p>
            <p class="quiet">{noFeatures}</p>
            <p class="quiet">{noFeaturesLabel}</p>
          </div>
        ) : (
          <>
            <FromDeviceStrip at={fromDevice.value ? copyAt.value : undefined} />
            <ErrorStrip lines={errors.value} retry={refresh} />
            <div class={errors.value.length > 0 ? "stale" : undefined}><FeatureGroups store={store} list={list} /></div>
          </>
        )}
    </div>
  );
}

/** The features in their groups (#4115): Needs you, In flight, Idle, then Finished (#3741), closed. A head has a chevron,
 * its words (Needs you in the attention colour) and its count after them in the tertiary colour. */
function FeatureGroups({ store, list }: { store: Store; list: ForgeFeature[] }) {
  const agents = Object.values(store.agents.value).flat();
  const groups = featureGroups(list, agents, approvals.value);
  const present = groups.map((g) => g.group);
  const waiting = new Set(approvals.value.map((r) => `P${shortRef(r)}`));
  return (
    <>
      {groups.map(({ group, features: shown }) => {
        const isOpen = groupOpen.value[group] ?? (group !== "finished" || groups.length === 1);
        const words = groupWords[group];
        return (
          <div key={group}>
            <button type="button" class={`work-group-head${group === "needsYou" ? " attention" : ""}`} aria-expanded={isOpen}
              aria-label={`${words}, ${shown.length}`}
              onClick={() => { groupOpen.value = { ...groupOpen.value, [group]: !isOpen }; }}
              title={isOpen ? `Fold ${words}` : `Show ${words}`}>
              <span class="chevron" aria-hidden="true">{isOpen ? "▾" : "▸"}</span>
              <span class="words">{words}</span>
              <span class="count">{shown.length}</span>
            </button>
            {isOpen && (
              <ul class="work-rows work-feature-rows">
                {shown.map((f) => {
                  const sessions = featureSessions(f, agents);
                  return (
                    <FeatureRow key={f.name} store={store} feature={f} agents={agents} group={group} approvals={waiting}
                      startOpen={startsOpen(group, present)} sessions={group === "inFlight" ? sessions.length : undefined}
                      needs={group === "needsYou" ? needsWords(f, sessions, approvals.value) : undefined} />
                  );
                })}
              </ul>
            )}
          </div>
        );
      })}
    </>
  );
}

/** A feature (note 3): line 1 its colour, title and label chip; line 2 its epics, what is in flight and what waits for
 * you; at the end a bar of its children done, in flight and not started (note 4). Open, its epics as lines with their
 * children in flight, then its issues with no epic in flight. */
function FeatureRow({ store, feature, agents, group, approvals: waiting, startOpen, sessions, needs }: {
  store: Store; feature: ForgeFeature; agents: Agent[]; group: FeatureGroup; approvals: ReadonlySet<string>; startOpen: boolean;
  sessions: number | undefined; needs: string | undefined;
}) {
  const key = feature.name.toLowerCase();
  const isOpen = featureOpen.value[key] ?? startOpen;
  const read = items.value[key];
  const dot = labelColor(feature.color);
  const shown = read ? openedFeature(read.items.map((i) => i.item)) : undefined;
  const epicHosts = read && shown ? read.items.filter((i) => shown.epics.includes(i.item)) : [];
  useEffect(() => {
    if (isOpen && !read && !itemReads.has(key)) void readItems(store, feature.name);
    if (isOpen && epicHosts.length > 0) readPlans(store, epicHosts);
  }, [isOpen, read]);

  const flights = (list: readonly ForgeItem[]) => flightOrder(list.flatMap((i) => { const f = inFlight(i, agents, waiting); return f ? [f] : []; }));
  const epics = (shown?.epics ?? []).map((e) => {
    const plan = plans.value[e.node.ref];
    if (typeof plan !== "object") return { epic: e, plan, flight: [] as InFlight[], delivery: progressDelivery(e) };
    const flight = flights(plan.children.map((c) => c.item));
    return { epic: e, plan, flight, delivery: planDelivery(plan, flight.length) };
  });
  const loose = flights(shown?.loose ?? []);
  const looseDelivery: Delivery = { done: 0, flight: loose.length, total: shown?.loose.length ?? 0 };
  const delivery = shown ? addDelivery([...epics.map((e) => e.delivery), looseDelivery]) : undefined;
  const allPlans = shown !== undefined && epics.every((e) => typeof e.plan === "object");
  const flightCount = allPlans ? epics.reduce((n, e) => n + e.flight.length, loose.length) : featureFlight(feature, agents);
  const line2 = [featureFlightWords(feature, flightCount)];
  if (sessions !== undefined) line2.push(sessionWords(sessions));
  if (group === "idle") { const u = updatedWords(feature); if (u) line2.push(u); }
  const legacy = delivery === undefined || delivery.total === 0 ? epicsDone(feature) : undefined;
  return (
    <li>
      <button type="button" class="work-feature-head" aria-expanded={isOpen} onClick={() => toggle(feature.name, isOpen)}
        title={isOpen ? `Fold ${feature.name}` : `Show ${feature.name}'s epics in flight`}>
        <span class="chevron" aria-hidden="true">{isOpen ? "▾" : "▸"}</span>
        <span class="dot" style={dot ? { background: dot } : undefined} aria-hidden="true" />
        <span class="work-row-main">
          <span class="work-row-head">
            <span class="work-title">{featureTitle(feature.name)}</span>
            <span class="work-feature-chip"><LabelChip label={{ name: `feature:${feature.name}`, ...feature.color ? { color: feature.color } : {} }} /></span>
          </span>
          <span class={`work-row-line small${needs ? " work-needs" : ""}`}>
            <span class={needs ? undefined : "quiet"}>{line2.join(" · ")}</span>
            {needs && <><span aria-hidden="true">·</span><span><span aria-hidden="true">⚠ </span>{needs}</span></>}
          </span>
        </span>
        {delivery && delivery.total > 0 ? (
          <span class="work-feature-done">
            <DeliveryBar delivery={delivery} />
            <span class="words quiet small">{deliveryWords(delivery)}</span>
          </span>
        ) : legacy !== undefined && (
          <span class="work-feature-done">
            <span class="work-plan-bar" aria-hidden="true"><span class="done" style={{ width: `${legacy * 100}%` }} /></span>
            <span class="words quiet small">{epicsDoneWords(feature)}</span>
          </span>
        )}
      </button>
      {isOpen && (
        <div class="work-feature-open">
          {read && read.errors.length > 0 && <ErrorStrip lines={read.errors} retry={() => { void readItems(store, feature.name); }} />}
          {!shown ? <PlaceholderRows count={2} />
            : shown.epics.length === 0 && shown.loose.length === 0 ? <p class="quiet small">{nothingOpen}</p>
            : (
              <>
                <ul class="work-feature-items">
                  {epics.map(({ epic, plan, flight, delivery: d }) => (
                    <EpicLine key={epic.node.ref} epic={epic} plan={plan} flight={flight} delivery={d} agents={agents} />
                  ))}
                </ul>
                {shown.loose.length > 0 && (
                  <>
                    <h4 class="small">Issues with no epic</h4>
                    <ul class="work-feature-items work-flight-lines">
                      {loose.slice(0, flightShown).map((f, i) => <FlightLine key={f.item.node.ref} flight={f} phone={i < flightShownPhone} />)}
                    </ul>
                    <Rest delivery={looseDelivery} />
                  </>
                )}
              </>
            )}
        </div>
      )}
    </li>
  );
}

/** An epic's line (notes 5 to 7): the epic glyph, its title, its number and where it is; at the end its bar, its
 * children closed of all, and its lead. Under it its children in flight (note 8) and the rest in words (note 9). */
function EpicLine({ epic, plan, flight, delivery, agents }: {
  epic: ForgeItem; plan: ForgePlan | string | undefined; flight: InFlight[]; delivery: Delivery; agents: Agent[];
}) {
  const lead = epicLead(epic.node, agents);
  const tone = lead?.state === "waitingOnUser" ? " attention" : lead && ["starting", "running"].includes(lead.state) ? " working" : "";
  const where = typeof plan === "object" ? whereWords(plan) : undefined;
  const leadWords = lead ? leadRowWords(lead.state) : "No lead";
  return (
    <li class="work-delivery-epic">
      <a class="work-feature-row work-delivery-epic-row" href={itemHref(epic)} title={`Open ${shortRef(epic.node.ref)}'s page`}
        onClick={(e) => openItem(e, epic)}>
        <EpicGlyph closed={epic.state === "closed"} />
        <span class="name">
          <span class="work-title"><ForgeTitle text={epic.title} /></span> <span class="quiet">{shortRef(epic.node.ref)}</span>
          {where && <span class="where quiet"> {where}</span>}
        </span>
        <span class="work-feature-epic-end small">
          <DeliveryBar delivery={delivery} />
          <span class="figures quiet" title="Sub-issues closed, of all">{`${delivery.done} of ${delivery.total}`}</span>
          <span class={`lead${tone}`}>{leadWords}</span>
        </span>
        <span class={`work-delivery-phone small${tone}`}>{[where, leadWords].filter(Boolean).join(" · ")}</span>
      </a>
      {plan === undefined ? <p class="work-delivery-rest quiet small">{readingWords}</p>
        : typeof plan === "string" ? <p class="work-delivery-rest quiet small">{plan}</p>
        : flight.length === 0 ? (
          <>
            <p class="work-delivery-rest quiet small">{nothingInFlight}</p>
          </>
        ) : (
          <>
            <ul class="work-feature-items work-flight-lines">
              {flight.slice(0, flightShown).map((f, i) => <FlightLine key={f.item.node.ref} flight={f} phone={i < flightShownPhone} />)}
            </ul>
            <Rest delivery={delivery} epic={epic} />
          </>
        )}
    </li>
  );
}

/** The rest under an epic or the loose issues, in words (notes 9, 11 and 15): the wide page's, and the phone's, which
 * shows fewer lines. On an epic, the wide words end with a link to its page. */
function Rest({ delivery, epic }: { delivery: Delivery; epic?: ForgeItem }) {
  const wide = restWords(delivery, Math.min(delivery.flight, flightShown));
  const phone = restWords(delivery, Math.min(delivery.flight, flightShownPhone));
  if (!wide && !phone) return null;
  return (
    <p class="work-delivery-rest quiet small">
      {wide && <span class="wide-line">{wide}{epic && <>{" · "}<a href={itemHref(epic)} onClick={(e) => openItem(e, epic)}>{openEpicWords}</a></>}</span>}
      {phone && <span class="short-line">{phone}</span>}
    </p>
  );
}

/** A child in flight (note 8): its mark, its number, its title, then what works on it; at the end its pull request. A
 * Needs you line is in the attention colour. `phone` is false for the lines past the phone's two. */
function FlightLine({ flight, phone }: { flight: InFlight; phone: boolean }) {
  const { item, mark, words, pr } = flight;
  return (
    <li class={phone ? undefined : "wide-only"}>
      <a class={`work-feature-row work-flight-row is-${mark}`} href={itemHref(item)} title={`Open ${shortRef(item.node.ref)}'s page`}
        onClick={(e) => openItem(e, item)}>
        <span class="mark" role="img" aria-label={mark === "attention" ? "Needs you" : "Working"}>{mark === "attention" ? "⚠" : "●"}</span>
        <span class="name"><span class="ref quiet">{shortRef(item.node.ref)}</span> <ForgeTitle text={item.title} /></span>
        <span class="words"><span class="sep" aria-hidden="true">· </span>{words}</span>
        {pr && <span class="pr small"><StateIcon kind="pr" state="open" size={12} />{pr}</span>}
      </a>
    </li>
  );
}

/** A bar in three parts (note 4): done (purple), in flight (green), not started (grey). */
function DeliveryBar({ delivery }: { delivery: Delivery }) {
  const s = deliveryShares(delivery);
  return (
    <span class="work-plan-bar" aria-hidden="true">
      <span class="done" style={{ width: `${s.done * 100}%` }} /><span class="running" style={{ width: `${s.flight * 100}%` }} />
    </span>
  );
}

/** The epic glyph (note 5): a ring with a quarter filled, green open and purple closed. */
function EpicGlyph({ closed }: { closed: boolean }) {
  return (
    <svg class={`work-epic-glyph${closed ? " closed" : ""}`} width="14" height="14" viewBox="0 0 16 16" role="img" aria-label={closed ? "Closed epic" : "Open epic"}>
      <circle cx="8" cy="8" r="6.5" fill="none" stroke="currentColor" stroke-width="1.5" /><path d="M8 8V3.5A4.5 4.5 0 0 1 12.5 8Z" fill="currentColor" />
    </svg>
  );
}

const itemHref = (item: ForgeItem) => routeHash({ nav: "work", section: "issue", item: item.node.ref });

/** A click opens the item's page here; a middle-click or ⌘-click in a new tab. */
function openItem(e: MouseEvent, item: ForgeItem) {
  if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
  e.preventDefault();
  e.stopPropagation();
  go({ nav: "work", section: "issue", item: item.node.ref });
}

/** Features' glyph: three sheets, one on another. */
function StackGlyph() {
  return <svg class="work-plan-glyph work-empty-glyph" width="32" height="32" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2 14 5 8 8 2 5zM2 8l6 3 6-3M2 11l6 3 6-3" /></svg>;
}
