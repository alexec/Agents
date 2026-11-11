// Work ▸ Features (#3269, spec 3265), as the window's WorkFeaturesPane, in the Work look (#4418,
// specs/4328-work-look/epic.md, Features): Board ▾ (#3282, Mac + web) and Refresh in the page's bar; then the groups
// (#4115) Needs you, In flight, Idle and Finished (folded, #3741), each head with its count. A feature (forge/features on
// each machine) is two lines: its colour, title and label chip; its counts and, in Needs you, what waits; a bar of its
// epics done at the end. Opened, its open epics (forge/issues with the feature), each a mini row with its bar and lead,
// and its issues with no epic. A row opens the issue's page. Under 700 px the chip and the bar's words go, and an epic's
// counts and lead go under its title.
import { signal } from "@preact/signals";
import type { ComponentChildren } from "preact";
import { useEffect } from "preact/hooks";
import type { Agent, ForgeFeature, ForgeItem } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import { boardChoices, boardName, errorWords, labelColor, noForgeHere, shortRef, withBoard } from "../model/work";
import { ErrorStrip, LabelChip, PlaceholderRows, RefreshButton, StateIcon } from "./WorkParts";
import { boardHosts, boards, forgeHosts, listHosts, loadBoards } from "../model/workLists";
import { Choice } from "./Work";
import {
  type FeatureGroup, epicLead, epicProgressWords, epicsDone, epicsDoneWords, featureCountWords, featureGroups, featureSessions, featureTitle,
  groupWords, leadRowWords, mergeFeatures, needsWords, noFeatures, noFeaturesLabel, noFeaturesTitle, nothingOpen, openedFeature, sessionWords,
} from "../model/workFeatures";
import { go, routeHash } from "../route";
import { ForgeTitle } from "../render/ForgeTitle";

// The list's state lives for the tab, so Back from an epic's page finds it as it was left.
const features = signal<ForgeFeature[] | null>(null);
/** The open pull requests labelled needs-approval, of every machine (#4115). */
const approvals = signal<string[]>([]);
const errors = signal<string[]>([]);
const opened = signal<ReadonlySet<string>>(new Set());
/** The groups a person opened or closed (#3741, #4115). Each is open until closed, except Finished,
 * which is closed until opened, unless every feature is in it. */
const groupOpen = signal<Readonly<Partial<Record<FeatureGroup, boolean>>>>({});
const items = signal<Readonly<Record<string, { items: ForgeItem[]; errors: string[] }>>>({});
const asked = signal(0);
/** Whether a read of the features runs, for Refresh's spin. */
const reading = signal(false);
/** The board chosen, by its url; empty for all. */
const board = signal("");
let read: string | undefined;

async function loadFeatures(store: Store) {
  const mine = asked.value;
  const on = board.value;
  const hosts = listHosts(store, on);
  const key = `${mine} ${on} ${hosts.map((h) => h.id).join(",")}`;
  if (read === key && features.value !== null) return;
  read = key;
  reading.value = true;
  features.value = null;
  approvals.value = [];
  errors.value = [];
  items.value = {};
  const got = await Promise.all(hosts.map(async (h) => {
    try {
      return { host: h, list: await store.link.call("forge/features", withBoard({}, on), h.id) };
    } catch (e) {
      return { host: h, list: { features: [], errors: [{ forge: "", message: describe(e) }] } };
    }
  }));
  if (asked.value !== mine || board.value !== on) return;
  reading.value = false;
  errors.value = got.flatMap(({ host, list }) => (list.errors ?? []).map((e) => errorWords(e, hosts.length > 1 ? host.name : undefined)));
  features.value = mergeFeatures(got.map(({ list }) => list.features));
  approvals.value = got.flatMap(({ list }) => list.approvals ?? []);
  for (const name of opened.value) void readItems(store, name);
}

/** An opened feature's open issues from every machine. */
async function readItems(store: Store, name: string) {
  const mine = asked.value;
  const on = board.value;
  const hosts = listHosts(store, on);
  const got = await Promise.all(hosts.map(async (h) => {
    const machine = hosts.length > 1 ? h.name : undefined;
    try {
      const list = await store.link.call("forge/issues", withBoard({ state: "open", limit: 100, feature: name }, on), h.id);
      return { items: list.items, errors: (list.errors ?? []).map((e) => errorWords(e, machine)) };
    } catch (e) {
      return { items: [], errors: [machine ? `${machine}: ${describe(e)}` : describe(e)] };
    }
  }));
  if (asked.value !== mine || board.value !== on) return;
  items.value = { ...items.value, [name.toLowerCase()]: { items: got.flatMap((g) => g.items), errors: got.flatMap((g) => g.errors) } };
}

function toggle(store: Store, name: string) {
  const key = name.toLowerCase();
  const next = new Set(opened.value);
  if (next.delete(key)) { opened.value = next; return; }
  next.add(key);
  opened.value = next;
  if (!items.value[key]) void readItems(store, name);
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
                    <FeatureRow key={f.name} store={store} feature={f} agents={agents}
                      sessions={group === "inFlight" ? sessions.length : undefined}
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

/** A feature (Features note 2): line 1 its colour, title and label chip; line 2 its counts and what waits for you; at
 * the end a bar of its epics done. Opened, its epics and its issues with no epic. */
function FeatureRow({ store, feature, agents, sessions, needs }: {
  store: Store; feature: ForgeFeature; agents: Agent[]; sessions: number | undefined; needs: string | undefined;
}) {
  const key = feature.name.toLowerCase();
  const isOpen = opened.value.has(key);
  const read = items.value[key];
  const dot = labelColor(feature.color);
  const shown = read ? openedFeature(read.items) : undefined;
  const done = epicsDone(feature);
  return (
    <li>
      <button type="button" class="work-feature-head" aria-expanded={isOpen} onClick={() => toggle(store, feature.name)}
        title={isOpen ? `Fold ${feature.name}` : `Show ${feature.name}'s open epics and issues`}>
        <span class="chevron" aria-hidden="true">{isOpen ? "▾" : "▸"}</span>
        <span class="dot" style={dot ? { background: dot } : undefined} aria-hidden="true" />
        <span class="work-row-main">
          <span class="work-row-head">
            <span class="work-title">{featureTitle(feature.name)}</span>
            <span class="work-feature-chip"><LabelChip label={{ name: `feature:${feature.name}`, ...feature.color ? { color: feature.color } : {} }} /></span>
          </span>
          <span class="work-row-line small">
            <span class="quiet">{[featureCountWords(feature), ...sessions !== undefined ? [sessionWords(sessions)] : []].join(" · ")}</span>
            {needs && <><span class="quiet" aria-hidden="true">·</span><span class="work-needs"><span aria-hidden="true">⚠ </span>{needs}</span></>}
          </span>
        </span>
        {done !== undefined && (
          <span class="work-feature-done">
            <span class="work-plan-bar" aria-hidden="true"><span class="done" style={{ width: `${done * 100}%` }} /></span>
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
                  {shown.epics.map((e) => {
                    const lead = epicLead(e.node, agents);
                    const p = e.progress && e.progress.total > 0 ? e.progress.done / e.progress.total : 0;
                    const tone = lead?.state === "waitingOnUser" ? " attention" : lead && ["starting", "running"].includes(lead.state) ? " working" : "";
                    return (
                      <li key={e.node.ref}>
                        <ItemLink item={e}>
                          <span class="work-feature-epic-end small">
                            <span class="work-plan-bar" aria-hidden="true"><span class="done" style={{ width: `${p * 100}%` }} /></span>
                            <span class="figures quiet" title="Sub-issues closed, of all">{epicProgressWords(e)}</span>
                            <span class={`lead${tone}`}>{leadRowWords(lead?.state)}</span>
                          </span>
                        </ItemLink>
                      </li>
                    );
                  })}
                </ul>
                {shown.loose.length > 0 && (
                  <>
                    <h4 class="small">Issues with no epic</h4>
                    <ul class="work-feature-items">
                      {shown.loose.map((i) => {
                        const level = i.level ? i.labels.find((l) => l.name.toLowerCase() === i.level) ?? { name: i.level } : undefined;
                        return <li key={i.node.ref}><ItemLink item={i}>{level && <LabelChip label={level} />}</ItemLink></li>;
                      })}
                    </ul>
                  </>
                )}
              </>
            )}
        </div>
      )}
    </li>
  );
}

/** A mini row (parts.md section 5): the state icon, the title, the number, then `children`; a link to the item's page. */
function ItemLink({ item, children }: { item: ForgeItem; children?: ComponentChildren }) {
  return (
    <a class="work-feature-row" href={routeHash({ nav: "work", section: "issue", item: item.node.ref })} title={`Open ${shortRef(item.node.ref)}'s page`}
      onClick={(e) => { if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return; e.preventDefault(); go({ nav: "work", section: "issue", item: item.node.ref }); }}>
      <StateIcon kind="issue" state={item.state} size={14} />
      <span class="name"><ForgeTitle text={item.title} /> <span class="quiet">{shortRef(item.node.ref)}</span></span>
      {children}
    </a>
  );
}

/** Features' glyph: three sheets, one on another. */
function StackGlyph() {
  return <svg class="work-plan-glyph work-empty-glyph" width="32" height="32" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2 14 5 8 8 2 5zM2 8l6 3 6-3M2 11l6 3 6-3" /></svg>;
}
