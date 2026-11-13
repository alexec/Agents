// The Now family of session cards (#5033, specs/session-cards/spec.md, family 5): what the agent
// works towards, at the top, and what it does or waits on now, at the foot. Both are a card on the
// well with the same parts: a mark, a bold line and a quiet detail, a meta on the right, a chevron
// when it has more, and a bar for a deadline or a count. No colour fills it: the bar is the accent
// (Paper v2). The window and the Remote draw NowCard.swift, with the same words (model/nowWords.ts).
import { createContext, type ComponentChildren } from "preact";
import { useContext } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Agent, Plan } from "../protocol/generated";
import { goalBudgetFraction, goalIsStopped, goalProgress, goalStatusWord, goalSummary } from "../model/goal";
import { planDone, planInForce, planStep, planSummary } from "../model/currentPlan";
import { nowShowLess, nowShowMore } from "../model/nowWords";
import { PlanView } from "./chat/Rows";
import { Icon } from "./Icon";

/** Whether the Now card around a part is open, and the way to open it. Null outside one. */
export const NowOpen = createContext<{ open: boolean; hasMore: boolean; toggle: () => void } | null>(null);

/** Whether the part is shown open: alone, it shows all. */
export function useNowOpen(): boolean {
  return useContext(NowOpen)?.open ?? true;
}

/** A Now card's head: mark, what in bold, a quiet detail, the meta, and the chevron when it has more. */
export function NowHead({ mark, title, detail, meta, closedMeta }: {
  mark: ComponentChildren; title: string; detail?: string | null | undefined; meta?: string | null | undefined;
  /** A meta that the detail says again, so it shows only while the card is closed. */
  closedMeta?: string | null | undefined;
}) {
  const card = useContext(NowOpen);
  const shownMeta = meta ?? (card?.open ? null : closedMeta);
  const row = (
    <>
      <span class="now-mark" aria-hidden="true">{mark}</span>
      <span class="now-what"><strong>{title}</strong>{detail && <span class="now-detail"> · {detail}</span>}</span>
      {shownMeta && <span class="now-meta">{shownMeta}</span>}
      {card?.hasMore && <Icon name={card.open ? "chevron-down" : "chevron-right"} class="chevron" />}
    </>
  );
  return card?.hasMore
    ? <button type="button" class="now-head" aria-expanded={card.open} title={card.open ? nowShowLess : nowShowMore}
      onClick={card.toggle}>{row}</button>
    : <div class="now-head">{row}</div>;
}

/** How far along, a thin bar in the accent. */
export function NowBar({ fraction, label }: { fraction: number; label?: string }) {
  const percent = Math.min(100, Math.max(0, fraction * 100));
  return label
    ? <span class="now-bar" role="progressbar" aria-label={label} aria-valuemin={0} aria-valuemax={100} aria-valuenow={percent}>
      <span style={{ width: `${percent}%` }} /></span>
    : <span class="now-bar" aria-hidden="true"><span style={{ width: `${percent}%` }} /></span>;
}

/**
 * What the agent works towards, at the head of the chat: the goal (#2742) and the plan in force
 * (#341) as one card with two rows, each opening on its own. It was two strips of the same shape.
 */
export function NowTop({ agent }: { agent: Agent | undefined }) {
  const goal = agent?.goal;
  const plan = agent && planInForce(agent);
  if (!goal && !plan) return null;
  return (
    <div class="now-top">
      <div class="now-card">
        {goal && <GoalRow agent={agent!} />}
        {plan && <PlanRow plan={plan} />}
      </div>
    </div>
  );
}

function GoalRow({ agent }: { agent: Agent }) {
  const open = useSignal(false);
  const goal = agent.goal!;
  const progress = goalProgress(goal);
  const fraction = goalBudgetFraction(goal);
  return (
    <button class={`now-row goal-row${open.value ? " open" : ""}`} aria-expanded={open.value} aria-label={goalSummary(goal)}
      onClick={() => (open.value = !open.value)}>
      <span class="now-line">
        <Icon name={goal.status === "complete" ? "circle-check" : "target"} class="now-mark" />
        <strong class="now-step">{goal.objective}</strong>
        <span class="now-meta">{goalStatusWord(goal)}</span>
        <Icon name={open.value ? "chevron-down" : "chevron-right"} class="chevron" />
      </span>
      {goal.reason !== undefined && (goalIsStopped(goal) || open.value) && <span class="now-sub">{goal.reason}</span>}
      {open.value && progress && <span class="now-sub">{progress}</span>}
      {fraction !== null && <NowBar fraction={fraction} />}
    </button>
  );
}

function PlanRow({ plan }: { plan: Plan }) {
  const open = useSignal(false);
  const done = planDone(plan);
  const total = plan.entries.length;
  return (
    <div class="plan-row">
      <button class="now-row" aria-expanded={open.value} aria-label={planSummary(plan)}
        onClick={() => (open.value = !open.value)}>
        <span class="now-line">
          <Icon name="square-check" class="now-mark" />
          <span class="now-step">{planStep(plan)}</span>
          <span class="now-meta">{done} of {total}</span>
          <Icon name={open.value ? "chevron-down" : "chevron-right"} class="chevron" />
        </span>
        <NowBar fraction={total ? done / total : 0} />
      </button>
      {open.value && <PlanView plan={plan} />}
    </div>
  );
}

/**
 * What the agent does or waits on now, the last thing before the prompt bar: the parts (the live
 * picture, a wait on sessions, the agent's wait on events), else `head`, the working line. Its
 * `detail` (leases, background work) shows when it is opened; it opens by itself on a picture.
 */
export function NowFoot({ parts, head, detail, live }: {
  parts: ComponentChildren[]; head: ComponentChildren; detail: ComponentChildren | null; live: boolean;
}) {
  const chosen = useSignal<boolean | null>(null);
  const open = chosen.value ?? live;
  const hasMore = detail !== null || parts.length > 0;
  if (!parts.length && head === null && detail === null) return null;
  return (
    <NowOpen.Provider value={{ open, hasMore, toggle: () => (chosen.value = !open) }}>
      <div class="now-card now-foot" role="group" aria-label="Now">
        {parts.length ? parts : head}
        {open && detail}
      </div>
    </NowOpen.Provider>
  );
}
