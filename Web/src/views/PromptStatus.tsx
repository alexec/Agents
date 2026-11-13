import { Strip } from "./Strip";
import { go } from "../route";
import type { Agent, CostState, PolicySetBy, SandboxChoice } from "../protocol/generated";
import { line } from "../model/orgPolicy";
import { optionLabel } from "./OrgPolicyLine";
import { fixedSandbox, sandboxChoiceWords, sandboxChoices, sandboxExplanation, sandboxRefusedBy, sandboxState, sandboxStateWords, sandboxWhy } from "../model/sandbox";
import { followsSettings } from "../model/levels";
import { costIsUnmeasured, dayTokenLimitReached, isAtMoneyLimit, isAtTokenLimit, tokenFigure } from "../model/limits";
import { priced } from "../model/runtimes";

// The limit strip's words, the window's and the Remote's too (CostLimitWords).
export const costLimitWords = {
  atItsLimit: "This agent reached its cost limit",
  goOn: "Let this one go on",
  goOnHelp: "Raises this agent's own ceiling. No other agent is changed.",
  raise: "Raise the limit",
  raiseHelp: "Opens Settings ▸ Agents ▸ Policy, where the limits are.",
  dayTokens: "The day's token limit has been reached",
  daySpending: "The day's spending limit has been reached",
  waits: "Anything you send waits until you allow more.",
  dayDetail: "What you send waits here, and goes when the day rolls over.",
};

/** Whether the agent, or the day, is at its limit. */
export function costLimitApplies(agent: Agent | undefined, costs: CostState | undefined): boolean {
  if (!agent || agent.state === "archived") return false;
  const limits = costs?.limits;
  return isAtMoneyLimit(agent, limits) || isAtTokenLimit(agent, limits) || dayTokenLimitReached(costs)
    || (!!limits?.daily && (costs?.today?.[limits.daily.currency] ?? 0) >= limits.daily.amount);
}

/** The limit's strip (#5034, last of the session's strips). It was a banner over the prompt bar; it moved to
 *  the top so that every "the agent cannot go on" is in one place (Alex, 2026-11-12). Orange, a warning. */
export function CostLimitStrip({ agent, costs, goOn }: { agent: Agent; costs: CostState | undefined; goOn: () => void }) {
  if (!costLimitApplies(agent, costs)) return null;
  const limits = costs?.limits;
  const atMoney = isAtMoneyLimit(agent, limits);
  const atAgentLimit = atMoney || isAtTokenLimit(agent, limits);
  const amount = Object.entries(agent.costToDate ?? {}).sort(([a], [b]) => a.localeCompare(b))
    .map(([currency, value]) => new Intl.NumberFormat(undefined, { style: "currency", currency }).format(value)).join(" · ");
  // Money, else tokens (#838): in the words of the limit it reached.
  const used = !atMoney && atAgentLimit ? `${(agent.tokensToDate ?? 0).toLocaleString()} tokens used.` : `${amount || ""} spent.`;
  const raise = { label: costLimitWords.raise, title: costLimitWords.raiseHelp, run: () => go({ nav: "settings", section: "agentsPolicy" }) };
  return atAgentLimit
    ? <Strip tone="warning" name="cost-limit" icon="coins" line={costLimitWords.atItsLimit} detail={`${used} ${costLimitWords.waits}`}
      primary={{ label: costLimitWords.goOn, title: costLimitWords.goOnHelp, run: goOn }} second={raise} />
    : <Strip tone="warning" name="cost-limit" icon="coins" line={dayTokenLimitReached(costs) ? costLimitWords.dayTokens : costLimitWords.daySpending}
      detail={costLimitWords.dayDetail} primary={raise} />;
}

export function ContextMeter({ agent, costs }: { agent: Agent; costs: CostState | undefined }) {
  const usage = agent.usage;
  const fraction = usage && usage.size > 0 ? Math.min(1, usage.used / usage.size) : undefined;
  const amounts = Object.entries(agent.costToDate ?? {}).sort(([a], [b]) => a.localeCompare(b))
    .map(([currency, value]) => new Intl.NumberFormat(undefined, { style: "currency", currency }).format(value)).join(" · ");
  const cost = amounts || (usage?.cost ? new Intl.NumberFormat(undefined, { style: "currency", currency: usage.cost.currency }).format(usage.cost.amount)
    : !costIsUnmeasured(agent) ? "$0.00" : null);
  // On an org account a figure is the runtime's list price, and says so (#999, FR-025).
  const shown = cost === null ? tokenFigure(agent, costs?.limits) ?? "Not measured" : priced(agent, cost);
  return <span class="context-meter" title={fraction === undefined ? "Cost reported by the runtime" : `${usage!.used.toLocaleString()} of ${usage!.size.toLocaleString()} tokens`}>
    {fraction !== undefined && <span class={`context-ring${fraction >= .85 ? " close" : ""}`} style={{ "--used": `${fraction * 100}%` }} aria-label={`${Math.round(fraction * 100)}% context used`} />}
    {shown}
  </span>;
}

export function SandboxCapsule({ runtimeID, override, runtimeDefault = "runtime", mode, onChange, disabled = false, setBy }: {
  runtimeID: string; override?: SandboxChoice | undefined; runtimeDefault?: SandboxChoice | undefined; mode?: string | undefined;
  onChange?: ((choice: SandboxChoice | undefined) => void) | undefined; disabled?: boolean | undefined;
  /** The organisation's mark while its policy requires the sandbox (#998): only On is in force. */
  setBy?: PolicySetBy | undefined;
}) {
  const state = sandboxState(runtimeID, override ?? runtimeDefault, mode);
  const choices = sandboxChoices(runtimeID);
  const why = sandboxWhy(runtimeID);
  // A runtime that cannot change its sandbox: its fixed value, and why (#2658).
  if (!choices.length || !onChange) {
    const shown = choices.length ? sandboxChoiceWords(override ?? runtimeDefault, runtimeID) : sandboxChoiceWords(fixedSandbox(runtimeID), runtimeID);
    return <span class="pill quiet" title={setBy ? line(setBy) : why ?? sandboxStateWords(state)}>{shown}</span>;
  }
  // While the organisation requires the sandbox, each choice but On is shown, dimmed, not chosen (#998).
  const refused = (choice: SandboxChoice | undefined) => sandboxRefusedBy(choice, setBy) !== undefined;
  const asked = override ?? runtimeDefault;
  return <label class="pill select" title={`${sandboxStateWords(state)}. ${sandboxExplanation(asked, runtimeID, runtimeID)}`}>
    <span aria-hidden="true">{sandboxChoiceWords(asked, runtimeID)} ▾</span>
    <select aria-label="Sandbox" disabled={disabled} value={asked} onChange={(e) => {
      const value = (e.currentTarget as HTMLSelectElement).value as SandboxChoice;
      // The value Settings gives, chosen again, follows Settings still.
      onChange(override === undefined && value === runtimeDefault ? undefined : value);
    }}>
      {choices.map((choice) => <option key={choice} value={choice} disabled={refused(choice)} title={refused(choice) ? line(setBy!) : undefined}>
        {optionLabel(override === undefined && choice === runtimeDefault ? `${sandboxChoiceWords(choice, runtimeID)} (${followsSettings})` : sandboxChoiceWords(choice, runtimeID),
          refused(choice) ? setBy : undefined)}</option>)}
    </select>
  </label>;
}
