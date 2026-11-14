// The Plan on an epic's Work page (#3268, spec 3265), in the Work look (#4418, specs/4328-work-look/epic.md notes 3 to 11
// and 15 to 19), as the window's WorkPlanSection (#4416): a box above the timeline. Its header has the stack glyph, Plan, a
// bar and "4 of 9 done · 2 running · $3.09 spent · about $4.70 to go", then the lead on its own line; then the epic's
// children step by step (forge/plan on the machine that read it), a step that is all done folded. A child is the two-line
// row of parts.md section 2: its state icon, title, level chip and the pull request lineage links to it (lineage/walk,
// lineage/cost); under it its number, its mark and what works on it, and its cost or estimate (#3560). A row opens its
// page; its ⋯ (on hover and keyboard focus) and a right-click open one menu: Blocked by (#3271), Open, Open lane and Open
// on GitHub. Add child is a row that opens the field. A standing epic's plan (#3662) is its query: the labels as chips
// and the rest in words, then its open issues in one list, the first ten and "N more", with no steps, Add child or
// Blocked by. Start lead and Open lead are the page header's. Under 700 px (note 19) the bar takes the width with the
// words under it, and a child is the phone row: its title on up to two lines, no level chip or pull request, a short
// line 2.
import { keepWork, keptWorkRead } from "../model/localCopy";
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { AgentState, ForgeDone, ForgeItemDetail, ForgePlan, ForgePlanChild, ForgePlanStep, ForgeStanding, LineageCostRollup, LineageEstimate, LineageLink } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import { sessionHost } from "../model/lineage";
import { doneWords, forgeName, openOnWords, shortRef } from "../model/work";
import { estimateRangeWords } from "../model/estimate";
import {
  addChildRequest, blockedByRequest, blockerChoices, childLevels, estimateWords, leadWords, lineWords, markWords, moreWords, namesIssue,
  phoneWords, planBar, planCostWords, planMark, planPR, planSessions, priorityLabel, progressWords, queryRestWords, standingShown,
  standingWords, startsFolded, stepTitle, stepWords, type PlanMark,
} from "../model/epicPlan";
import { isMenuKey, openContextMenu, type MenuItem } from "./ContextMenu";
import { go, routeHash } from "../route";
import { ForgeTitle } from "../render/ForgeTitle";
import { ErrorStrip, LabelChip, PlaceholderRows, StateIcon } from "./WorkParts";
import { Icon, type IconName } from "./Icon";

const holdsRuntime = (s: AgentState) => s === "starting" || s === "running" || s === "waitingOnUser";
/** The mark's icon before line 2's words; a closed child's state icon says it is done. */
const markIcon: Record<PlanMark, IconName | undefined> = { done: undefined, working: "dot", attention: "triangle-alert", waiting: "circle", blocked: "ban" };

export function WorkPlan({ store, host, lineageHost, detail, asked, estimates = [], writes, waiting = false, wrote, fromCopy }: {
  store: Store; host: string; lineageHost: string | undefined; detail: ForgeItemDetail; asked: number;
  estimates?: readonly LineageEstimate[]; writes: boolean;
  /** The page is this device's copy (#4930): no changes, and no words on why, until the machine answers. */
  waiting?: boolean; wrote: () => void;
  /** Told when the plan drawn from this device's copy was read, until its machine answers, and undefined after (#5142):
   * the page's one "From this device" strip says the oldest of it and the item's. */
  fromCopy?: (at: number | undefined) => void;
}) {
  const plan = useSignal<ForgePlan | null>(null);
  const problem = useSignal<string | null>(null);
  /** The plan on screen came from this device's copy (#4930): no changes until its machine answers. */
  const fromDevice = useSignal(false);
  /** When the plan on screen was read (#5142): this device's copy's time, or the last read that worked. */
  const planAt = useSignal<number | undefined>(undefined);
  const rollups = useSignal<Record<string, LineageCostRollup>>({});
  const links = useSignal<Record<string, LineageLink[]>>({});
  const said = useSignal<{ words: string; failed: boolean } | null>(null);
  const adding = useSignal(false);
  const newChild = useSignal("");
  const level = useSignal("task");
  const busy = useSignal(false);
  const changed = useSignal(0);
  /** The steps a person folded or opened, until the page is read again. */
  const folded = useSignal<Readonly<Record<number, boolean>>>({});
  /** A standing epic's list past its first ten. */
  const all = useSignal(false);
  const field = useRef<HTMLInputElement>(null);
  const node = detail.item.node;
  useEffect(() => { folded.value = {}; }, [node.ref, asked]);
  // The page's strip says when a plan from the copy was read, until the machine answers (#5142).
  const copyAt = fromDevice.value && !problem.value ? planAt.value : undefined;
  useEffect(() => { fromCopy?.(copyAt); }, [copyAt]);
  useEffect(() => () => fromCopy?.(undefined), []);
  useEffect(() => {
    let current = true;
    // After a write the plan stays up while it is read again, and its line says what was done.
    if (changed.value === 0) said.value = null;
    void (async () => {
      // Seen before: this device's copy at once, until the machine answers (#4930).
      if (!plan.peek()) {
        const kept = await keptWorkRead<ForgePlan>("plan", node.ref);
        if (current && kept && !plan.peek()) { plan.value = kept.value; planAt.value = kept.at; fromDevice.value = true; }
      }
      let got: ForgePlan;
      try {
        got = await store.link.call("forge/plan", { node }, host);
      } catch (e) {
        // A read after one came keeps the last plan, dimmed under the strip (state 2).
        if (current) problem.value = describe(e);
        return;
      }
      if (!current) return;
      plan.value = got;
      planAt.value = Date.now();
      fromDevice.value = false;
      problem.value = null;
      keepWork("plan", node.ref, got);
      if (!lineageHost) { rollups.value = {}; links.value = {}; return; }
      // Each child's cost and links: the links name a lane at once, the cost once it banked a turn.
      const read = await Promise.all(got.children.map(async (c) => {
        const [cost, walk] = await Promise.all([
          store.link.call("lineage/cost", { node: c.item.node }, lineageHost).catch(() => undefined),
          store.link.call("lineage/walk", { node: c.item.node }, lineageHost).catch(() => undefined),
        ]);
        return { ref: c.item.node.ref, cost, links: walk?.links ?? [] };
      }));
      if (!current) return;
      rollups.value = Object.fromEntries(read.flatMap((r) => r.cost ? [[r.ref, r.cost]] : []));
      links.value = Object.fromEntries(read.map((r) => [r.ref, r.links]));
    })();
    return () => { current = false; };
  }, [node.ref, host, lineageHost, asked, changed.value]);
  useEffect(() => { if (adding.value) field.current?.focus(); }, [adding.value]);

  const sessions = (c: ForgePlanChild) => planSessions(c.item.node, links.value[c.item.node.ref] ?? [], rollups.value[c.item.node.ref]);
  const chatOf = (id: string) => {
    const h = sessionHost(store.agents.value, id);
    const chat = h ? store.agent(h, id) : undefined;
    return h && chat ? { host: h, chat } : undefined;
  };
  const states = (c: ForgePlanChild): AgentState[] => sessions(c).flatMap((id) => { const s = chatOf(id)?.chat.state; return s ? [s] : []; });
  const openSession = (id: string) => {
    const at = chatOf(id);
    if (at) go({ host: at.host, folder: at.chat.worktree?.folder || at.chat.cwd, session: at.chat.id });
  };
  /** The first session that runs on a child, for "Working · “its title”" and Open lane. */
  const lane = (c: ForgePlanChild) => {
    const ids = sessions(c);
    const live = ids.find((id) => { const s = chatOf(id)?.chat.state; return s !== undefined && holdsRuntime(s); }) ?? ids[0];
    const title = live ? chatOf(live)?.chat.title : undefined;
    return live && title ? { id: live, title } : undefined;
  };

  const write = async (method: "forge/add-child" | "forge/blocked-by", params: unknown, then?: () => void) => {
    busy.value = true;
    try {
      const done = await store.link.call(method, params as never, host) as ForgeDone;
      then?.();
      said.value = { words: doneWords(method, done), failed: false };
      changed.value++;
      wrote();
    } catch (e) {
      said.value = { words: describe(e), failed: true };
    } finally {
      busy.value = false;
    }
  };
  const addChild = () => {
    if (!newChild.value.trim()) return;
    void write("forge/add-child", addChildRequest(node, newChild.value, level.value), () => { newChild.value = ""; });
  };
  const names = namesIssue(newChild.value);

  const p = plan.value;
  /** Add child and Blocked by: an open epic, not a standing one, on a machine that writes. */
  const changes = !!p && writes && !fromDevice.value && p.item.state === "open" && !p.standing;
  const running = p ? p.children.filter((c) => states(c).some(holdsRuntime)).length : 0;

  /** The row's menu (note 9): Blocked by, with a tick on each child that blocks it now; Open; Open lane; Open on GitHub. */
  const menu = (c: ForgePlanChild, pl: ForgePlan): MenuItem[] => {
    const ref = shortRef(c.item.node.ref);
    const l = lane(c);
    return [
      ...changes && pl.children.length > 1 ? [
        { label: `${ref} is blocked by`, heading: true, run: () => {} },
        ...blockerChoices(c, pl).map(({ child: other, on }): MenuItem => ({
          label: `${shortRef(other.item.node.ref)} ${other.item.title}`, checked: on, disabled: busy.value,
          help: on ? "Take it off" : `${ref} waits for it`,
          run: () => void write("forge/blocked-by", blockedByRequest(c, other.item.node, !on)),
        })),
      ] : [],
      { label: `Open ${ref}`, run: () => go({ nav: "work", section: "issue", item: c.item.node.ref }) },
      ...l ? [{ label: `Open lane “${l.title}”`, run: () => openSession(l.id) }] : [],
      ...c.item.url ? [{ label: openOnWords(c.item.node.ref), run: () => { open(c.item.url, "_blank", "noopener,noreferrer"); } }] : [],
    ];
  };

  const row = (c: ForgePlanChild, pl: ForgePlan) => {
    const rollup = rollups.value[c.item.node.ref];
    const pr = planPR(rollup);
    const st = states(c);
    const mark = planMark(c, pr, st);
    const l = lane(c);
    const words = lineWords(c, mark, pr, st, l?.title, pl);
    const short = phoneWords(words);
    const cost = planCostWords(rollup);
    const est = c.item.state === "open" ? estimates.find((e) => e.node.ref === c.item.node.ref) : undefined;
    const estWords = est ? estimateWords(est) : undefined;
    const priority = pl.standing ? priorityLabel(c.item) : undefined;
    const ref = shortRef(c.item.node.ref);
    const levelLabel = c.item.level ? c.item.labels.find((x) => x.name.toLowerCase() === c.item.level) ?? { name: c.item.level } : undefined;
    const items = () => menu(c, pl);
    const icon = markIcon[mark];
    return (
      <li key={c.item.node.ref} class="work-plan-item" onContextMenu={(e) => openContextMenu(e, items())}>
        {/* A link: a click opens the page here, a middle-click or ⌘-click in a new tab. */}
        <a class="work-plan-row" href={routeHash({ nav: "work", section: "issue", item: c.item.node.ref })} title={`Open ${ref}'s page`}
          onClick={(e) => { if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return; e.preventDefault(); go({ nav: "work", section: "issue", item: c.item.node.ref }); }}
          onKeyDown={(e) => { if (isMenuKey(e)) openContextMenu(e, items()); }}>
          <span class="work-row-icon"><StateIcon kind="issue" state={c.item.state} /></span>
          <span class="work-row-main">
            <span class="work-row-head">
              <span class="work-title"><ForgeTitle text={c.item.title} /></span>
              {levelLabel && <span class="work-plan-level"><LabelChip label={levelLabel} /></span>}
              {pr && (
                <span class="work-plan-pr small" aria-label={`Pull request ${shortRef(pr.node.ref)} ${pr.outcome ?? "open"}`}>
                  <StateIcon kind="pr" state={pr.outcome ?? "open"} size={14} />{shortRef(pr.node.ref)}</span>
              )}
            </span>
            <span class="work-row-line small">
              <span class="quiet">{ref}</span>
              {words && <>
                <span class="quiet" aria-hidden="true">·</span>
                <span class={`work-plan-mark is-${mark}`} aria-label={mark === "done" ? words : `${markWords[mark]}: ${words}`}>
                  {icon && <><Icon name={icon} /> </>}<span class="wide-line">{words}</span><span class="short-line">{short}</span>
                </span>
              </>}
              <span class="work-plan-end">
                {priority && <LabelChip label={priority} />}
                {cost ? <span class="quiet work-plan-cost">{cost}</span>
                  : estWords && est && <span class="work-plan-cost work-plan-estimate" title={estimateRangeWords(est)}>{estWords}</span>}
              </span>
            </span>
          </span>
        </a>
        <button type="button" class="work-plan-more" aria-label={`More for ${ref}`} title={`More for ${ref}`} aria-haspopup="menu"
          onClick={(e) => openContextMenu(e, items())}>⋯</button>
      </li>
    );
  };

  const stepBand = (s: ForgePlanStep, pl: ForgePlan, isFolded: boolean) => {
    const title = stepTitle(s, pl);
    const [head, ...rest] = title.split(" · ");
    const words = stepWords(s, pl, rollups.value);
    return (
      <button type="button" class="work-plan-band" aria-expanded={!isFolded} title={isFolded ? `Show ${title}` : `Fold ${title}`}
        onClick={() => { folded.value = { ...folded.value, [s.step]: !isFolded }; }}>
        <Icon name={isFolded ? "chevron-right" : "chevron-down"} class="chevron" />
        <span><span class="strong">{head}</span>{rest.length > 0 && ` · ${rest.join(" · ")}`}</span>
        <span class="end">{words}</span>
      </button>
    );
  };

  return (
    <section class={`work-plan${p?.standing ? " standing" : ""}`} aria-label="Plan" aria-busy={!p && !problem.value}>
      {p ? (
        <>
          <Header plan={p} running={running} rollups={Object.values(rollups.value)} estimates={estimates} />
          <LeadLine store={store} plan={p} open={openSession} />
          {problem.value && <div class="work-plan-strip"><ErrorStrip lines={[problem.value]} retry={() => { changed.value++; }} at={planAt.value} /></div>}
          <div class={`work-plan-body${problem.value ? " stale" : ""}`}>
            {p.standing && <Query plan={p} standing={p.standing} running={running} rollups={Object.values(rollups.value)} />}
            {p.children.length === 0 ? !p.standing?.error && (
              <div class="work-plan-empty">
                <p class="strong">{p.standing ? "No open issues match its query." : "No children yet."}</p>
                {changes && <p class="quiet small">Add a story, a task or a spike, or #12 for an issue that is there.</p>}
              </div>
            ) : p.standing ? (
              <>
                <div class="work-plan-band still">In order: priority, then the oldest</div>
                <ul class="work-plan-rows">{(all.value ? p.children : p.children.slice(0, standingShown)).map((c) => row(c, p))}</ul>
                {!all.value && moreWords(p.children.length) && (
                  <button type="button" class="link work-plan-more-rows" onClick={() => { all.value = true; }}>{moreWords(p.children.length)}</button>
                )}
              </>
            ) : p.steps.map((s) => {
              const isFolded = folded.value[s.step] ?? (startsFolded(s, p) || p.item.state === "closed");
              return (
                <div key={s.step} class="work-plan-step">
                  {stepBand(s, p, isFolded)}
                  {!isFolded && <ul class="work-plan-rows">{p.children.filter((c) => c.step === s.step).map((c) => row(c, p))}</ul>}
                </div>
              );
            })}
            {changes ? (
              <div class="work-plan-add">
                {adding.value || p.children.length === 0 ? (
                  <form class="work-plan-add-field" onSubmit={(e) => { e.preventDefault(); addChild(); }}>
                    <input ref={field} type="text" aria-label="Child" placeholder="New child's title, or #12" value={newChild.value}
                      onInput={(e) => { newChild.value = (e.target as HTMLInputElement).value; }}
                      onKeyDown={(e) => { if (e.key === "Escape" && p.children.length > 0) { adding.value = false; newChild.value = ""; } }} />
                    <select aria-label="Level" value={level.value} disabled={names}
                      title={names ? "An issue that is there keeps its labels" : "The new child's level"}
                      onChange={(e) => { level.value = (e.target as HTMLSelectElement).value; }}>
                      {childLevels.map((l) => <option key={l} value={l}>{l ? l.charAt(0).toUpperCase() + l.slice(1) : "No level"}</option>)}
                    </select>
                    <button type="submit" class="prominent" disabled={busy.value || !newChild.value.trim()}
                      title={names ? "Make this issue a child of the epic" : "Open a new issue as a child of the epic, in its feature"}>Add</button>
                    {busy.value && <span class="work-spinner" aria-label="Working" />}
                  </form>
                ) : (
                  <button type="button" class="work-plan-add-row" onClick={() => { adding.value = true; }}
                    title="Open a new issue as a child of the epic, or make an issue that is there one"><span aria-hidden="true">+</span>Add child</button>
                )}
                {said.value && <p class={said.value.failed ? "hint failure small" : "quiet small"} role="status">{said.value.words}</p>}
              </div>
            ) : !writes && !waiting && !fromDevice.value && p.item.state === "open" && !p.standing && (
              <p class="work-plan-no-writes quiet small">No machine of yours can write to {forgeName(p.item.node.ref)}.</p>
            )}
          </div>
        </>
      ) : problem.value ? (
        <>
          <div class="work-plan-head"><PlanTitle standing={detail.item.standing === true} /></div>
          <div class="work-plan-could-not" role="alert">
            <span class="mark" aria-hidden="true"><Icon name="triangle-alert" /></span>
            <p class="strong">Could not read the plan</p>
            <p class="quiet small">{problem.value}</p>
            <button type="button" onClick={() => { changed.value++; }}>Try again</button>
          </div>
        </>
      ) : (
        // The first read (state 1): Plan, a grey bar, No lead, four placeholder rows. No spinner.
        <>
          <div class="work-plan-head"><PlanTitle standing={false} /><span class="work-plan-bar placeholder" /></div>
          <p class="work-plan-lead quiet small placeholder">No lead</p>
          <PlaceholderRows count={4} />
        </>
      )}
    </section>
  );
}

/** The glyph and Plan; a standing epic's says "never closes" at its end. */
function PlanTitle({ standing }: { standing: boolean }) {
  return (
    <span class="work-plan-name">
      {standing
        ? <svg class="work-plan-glyph" width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><path d="M13 8a5 5 0 0 1-8.6 3.5M3 8a5 5 0 0 1 8.6-3.5M11.8 1.8v2.9H8.9M4.2 14.2v-2.9h2.9" /></svg>
        : <svg class="work-plan-glyph" width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2 14 5 8 8 2 5zM2 8l6 3 6-3M2 11l6 3 6-3" /></svg>}
      <span class="strong">Plan</span>
    </span>
  );
}

/** The header (note 3): Plan, a bar (purple: done; green: running; grey: the rest) and the figures; a standing epic's
 * says "never closes". Under 700 px the bar takes the width and the words go under it. */
function Header({ plan, running, rollups, estimates }: { plan: ForgePlan; running: number; rollups: LineageCostRollup[]; estimates: readonly LineageEstimate[] }) {
  if (plan.standing) {
    return <div class="work-plan-head"><PlanTitle standing /><span class="work-plan-never quiet small">never closes</span></div>;
  }
  const bar = planBar(plan, running);
  return (
    <div class="work-plan-head">
      <PlanTitle standing={false} />
      <span class="work-plan-bar" aria-hidden="true">
        <span class="done" style={{ width: `${bar.done * 100}%` }} /><span class="running" style={{ width: `${bar.running * 100}%` }} />
      </span>
      <span class="work-plan-figures quiet small">{progressWords(plan, running, rollups, estimates)}</span>
    </div>
  );
}

/** The lead (note 4): its avatar, Lead, the session's title (it opens the chat) and its state in words; with none, No lead
 * in grey. */
function LeadLine({ store, plan, open }: { store: Store; plan: ForgePlan; open: (id: string) => void }) {
  const lead = plan.lead;
  if (!lead) return <p class="work-plan-lead quiet small"><PersonGlyph />No lead</p>;
  const id = lead.session.toUpperCase();
  const h = sessionHost(store.agents.value, id);
  const chat = h ? store.agent(h, id) : undefined;
  const state = chat?.state ?? lead.state;
  const title = chat?.title ?? lead.title;
  return (
    <p class="work-plan-lead small">
      <span class="work-plan-lead-mark" aria-hidden="true"><Icon name="sparkles" /></span>
      <span>Lead</span>
      <button type="button" class="link" disabled={!chat} title="The lead's chat" onClick={() => open(id)}>{title ? `“${title}”` : "A session"}</button>
      <LeadState state={state} />
    </p>
  );
}

/** A lead's state in words after a dot (note 4): green while it works, the attention colour when it needs you, grey otherwise. */
export function LeadState({ state }: { state: AgentState }) {
  const tone = state === "waitingOnUser" ? "attention" : holdsRuntime(state) ? "working" : "quiet";
  return <span class={`work-lead-state ${tone}`}><span class="dot" aria-hidden="true" />{leadWords(state)}</span>;
}

/** A standing epic's query (note 17): its labels as chips, then the rest in words, then its counts; or, with no query,
 * the error from its standing block in a red strip (state 8) and a link to edit the epic's body on the forge. */
function Query({ plan, standing, running, rollups }: { plan: ForgePlan; standing: ForgeStanding; running: number; rollups: LineageCostRollup[] }) {
  if (standing.error) {
    return (
      <div class="work-plan-query-error small" role="status">
        <Icon name="ban" /><span class="words">{standing.error}</span>
        {plan.item.url && <a href={plan.item.url} target="_blank" rel="noopener noreferrer">Edit on {forgeName(plan.item.node.ref)}</a>}
      </div>
    );
  }
  return (
    <div class="work-plan-query small" title="The standing block in this epic's body: its plan is this query, in priority order, then the oldest">
      <p>
        <span class="quiet">Query</span>
        {standing.labels.map((name) => <LabelChip key={name} label={plan.item.labels.find((l) => l.name === name) ?? { name }} />)}
        <span class="quiet">{queryRestWords(standing)}</span>
      </p>
      <p class="quiet">{standingWords(plan, running, rollups)}</p>
    </div>
  );
}

function PersonGlyph() {
  return <svg class="work-plan-glyph" width="14" height="14" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="5.5" r="2.75" /><path d="M2.75 14a5.25 5.25 0 0 1 10.5 0" /></svg>;
}
