// The Plan section on an epic's Work page (#3268, spec 3265), as the window's WorkPlanSection: the
// epic's children step by step (forge/plan on the machine that read it), each with its mark, level,
// issue, the lane and PR that work on it and its cost (from lineage, lineage/walk and lineage/cost); a header with the
// lead, the children done and running, and the total cost; and Start lead (the lead skill's form, in
// the epic's folder) or Open lead. A row opens its issue's page. Where the machine writes to the
// forge, the plan changes here too (#3271): Add child (a new issue, or one that is there) under the
// steps, and each row's Blocked by menu of the other children; `wrote` reads the page again.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { AgentState, ForgeDone, ForgeItemDetail, ForgePlan, ForgePlanChild, LineageCostRollup, LineageLink } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import { sessionHost } from "../model/lineage";
import { doneWords, shortRef } from "../model/work";
import {
  addChildRequest, blockedByRequest, blockedWords, blockerChoices, childLevels, leadStart, leadWords, markWords, namesIssue, planCostWords,
  planMark, planPR, planSessions, planWorkWords, progressWords, stepTitle, type PlanMark,
} from "../model/epicPlan";
import { openContextMenu, type MenuItem } from "./ContextMenu";
import { offerStart } from "./NewAgent";
import { go } from "../route";
import { ForgeTitle } from "../render/ForgeTitle";

const markClass: Record<PlanMark, string> = { "✓": "done", "◐": "working", "⚠": "attention", "○": "waiting", "⊘": "blocked" };
const holdsRuntime = (s: AgentState) => s === "starting" || s === "running" || s === "waitingOnUser";

export function WorkPlan({ store, host, lineageHost, detail, asked, writes, wrote }: {
  store: Store; host: string; lineageHost: string | undefined; detail: ForgeItemDetail; asked: number; writes: boolean; wrote: () => void;
}) {
  const plan = useSignal<ForgePlan | null>(null);
  const problem = useSignal<string | null>(null);
  const rollups = useSignal<Record<string, LineageCostRollup>>({});
  const links = useSignal<Record<string, LineageLink[]>>({});
  const said = useSignal<{ words: string; failed: boolean } | null>(null);
  const newChild = useSignal("");
  const level = useSignal("task");
  const busy = useSignal(false);
  const changed = useSignal(0);
  const node = detail.item.node;
  useEffect(() => {
    let current = true;
    // After a write the plan stays up while it is read again, and its line says what was done.
    if (changed.value === 0) {
      plan.value = null;
      said.value = null;
    }
    problem.value = null;
    rollups.value = {};
    links.value = {};
    void (async () => {
      let got: ForgePlan;
      try {
        got = await store.link.call("forge/plan", { node }, host);
      } catch (e) {
        if (current) problem.value = describe(e);
        return;
      }
      if (!current) return;
      plan.value = got;
      if (!lineageHost) return;
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

  const states = (c: ForgePlanChild): AgentState[] => planSessions(c.item.node, links.value[c.item.node.ref] ?? [], rollups.value[c.item.node.ref]).flatMap((id) => {
    const h = sessionHost(store.agents.value, id);
    const state = h ? store.agent(h, id)?.state : undefined;
    return state ? [state] : [];
  });
  const openSession = (id: string) => {
    const h = sessionHost(store.agents.value, id);
    const chat = h ? store.agent(h, id) : undefined;
    return h && chat ? () => go({ host: h, folder: chat.worktree?.folder || chat.cwd, session: chat.id }) : undefined;
  };
  const startLead = () => {
    if (!detail.start) return;
    if (!detail.item.folder) { said.value = { words: "No folder on this machine is on this issue's repo.", failed: true }; return; }
    const why = offerStart(store, host, detail.item.folder, leadStart(detail.start, detail.item.url));
    said.value = why ? { words: why, failed: true } : null;
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
  const blockedByMenu = (event: MouseEvent, child: ForgePlanChild, p: ForgePlan) => openContextMenu(event,
    blockerChoices(child, p).map(({ child: other, on }): MenuItem => ({
      label: `${on ? "✓ " : ""}${shortRef(other.item.node.ref)} ${other.item.title}`,
      help: on ? "Take it off" : `${shortRef(child.item.node.ref)} waits for it`,
      run: () => void write("forge/blocked-by", blockedByRequest(child, other.item.node, !on)),
    })));
  const addChild = () => {
    if (!newChild.value.trim()) return;
    void write("forge/add-child", addChildRequest(node, newChild.value, level.value), () => { newChild.value = ""; });
  };
  const names = namesIssue(newChild.value);

  const p = plan.value;
  const running = p ? p.children.filter((c) => states(c).some(holdsRuntime)).length : 0;
  const lead = p?.lead;
  const openLead = lead ? openSession(lead.session.toUpperCase()) : undefined;
  return (
    <section class="work-plan" aria-label="Plan">
      <h3>Plan</h3>
      {problem.value ? <p class="hint">{problem.value}</p>
        : !p ? <p class="hint">Loading…</p>
        : (
          <>
            <div class="work-plan-head">
              {lead
                ? <span class={lead.state === "waitingOnUser" ? "attention" : undefined}>
                  {leadWords(lead, store.agent(sessionHost(store.agents.value, lead.session.toUpperCase()) ?? "", lead.session.toUpperCase())?.title)}</span>
                : <span class="quiet">No lead</span>}
              <span class="quiet">{progressWords(p, running, Object.values(rollups.value))}</span>
              {lead
                ? <button type="button" disabled={!openLead} onClick={openLead} title="The lead's chat">Open lead</button>
                : detail.start && p.item.state === "open" && <button type="button" class="prominent" onClick={startLead}
                  title="The new-session form in this epic's folder, filled in for a lead with the lead skill">Start lead</button>}
            </div>
            {said.value && <p class={said.value.failed ? "hint failure small" : "quiet small"} role="status">{said.value.words}</p>}
            {p.children.length === 0 ? <p class="hint">No sub-issues yet.</p> : (
              <div class="work-plan-steps">
                {p.steps.map((s) => (
                  <div key={s.step} class="work-plan-step">
                    <h4 class="small">{stepTitle(s, p)}</h4>
                    <ul>
                      {p.children.filter((c) => c.step === s.step).map((c) => {
                        const rollup = rollups.value[c.item.node.ref];
                        const pr = planPR(rollup);
                        const st = states(c);
                        const mark = planMark(c, pr, st);
                        const work = planWorkWords(pr, st) ?? blockedWords(c);
                        const cost = planCostWords(rollup);
                        return (
                          <li key={c.item.node.ref} class="work-plan-item">
                            <button type="button" class="work-plan-row" title={`Open ${shortRef(c.item.node.ref)}'s page`}
                              onClick={() => go({ nav: "work", section: "issue", item: c.item.node.ref })}>
                              <span class={`work-plan-mark ${markClass[mark]}`} title={markWords[mark]} aria-label={markWords[mark]}>{mark}</span>
                              <span class="quiet work-plan-level">{c.item.level ?? ""}</span>
                              <span class="work-ref">{shortRef(c.item.node.ref)}</span>
                              <span class="work-plan-title"><ForgeTitle text={c.item.title} /></span>
                              {work && <span class="quiet small">{work}</span>}
                              {cost && <span class="quiet small work-plan-cost">{cost}</span>}
                            </button>
                            {writes && p.children.length > 1 && (
                              <button type="button" class="work-plan-blocked" disabled={busy.value} aria-label="Blocked by"
                                title={`Blocked by: which children ${shortRef(c.item.node.ref)} waits for`}
                                onClick={(e) => blockedByMenu(e, c, p)}>Blocked by ▾</button>
                            )}
                          </li>
                        );
                      })}
                    </ul>
                  </div>
                ))}
              </div>
            )}
            {writes && p.item.state === "open" && (
              <form class="work-plan-add" onSubmit={(e) => { e.preventDefault(); addChild(); }}>
                <input type="text" aria-label="Child" placeholder="New child's title, or #12 for an issue that is there"
                  value={newChild.value} onInput={(e) => { newChild.value = (e.target as HTMLInputElement).value; }} />
                <select aria-label="Level" value={level.value} disabled={names}
                  title={names ? "An issue that is there keeps its labels" : "The new child's level"}
                  onChange={(e) => { level.value = (e.target as HTMLSelectElement).value; }}>
                  {childLevels.map((l) => <option key={l} value={l}>{l ? l.charAt(0).toUpperCase() + l.slice(1) : "No level"}</option>)}
                </select>
                <button type="submit" disabled={busy.value || !newChild.value.trim()}
                  title={names ? "Make this issue a child of the epic" : "Open a new issue as a child of the epic, in its feature"}>Add child</button>
                {busy.value && <span class="quiet small">Working…</span>}
              </form>
            )}
          </>
        )}
    </section>
  );
}
