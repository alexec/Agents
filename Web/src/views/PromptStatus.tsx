import type { Agent, CostState, PolicySetBy, SandboxChoice } from "../protocol/generated";
import { line } from "../model/orgPolicy";
import { optionLabel } from "./OrgPolicyLine";
import { fixedSandbox, sandboxChoiceWords, sandboxChoices, sandboxExplanation, sandboxState, sandboxStateWords, sandboxWhy } from "../model/sandbox";
import { followsSettings } from "../model/levels";
import { costIsUnmeasured, dayTokenLimitReached, isAtMoneyLimit, isAtTokenLimit, tokenFigure } from "../model/limits";
import { priced } from "../model/runtimes";

export function CostLimitBanner({ agent, costs, goOn }: { agent: Agent; costs: CostState | undefined; goOn: () => void }) {
  const limits = costs?.limits;
  const atMoney = isAtMoneyLimit(agent, limits);
  const atTokens = isAtTokenLimit(agent, limits);
  const atAgentLimit = atMoney || atTokens;
  const atDayTokens = dayTokenLimitReached(costs);
  const atDayLimit = atDayTokens || (!!limits?.daily && (costs?.today?.[limits.daily.currency] ?? 0) >= limits.daily.amount);
  const amount = Object.entries(agent.costToDate ?? {}).sort(([a], [b]) => a.localeCompare(b))
    .map(([currency, value]) => new Intl.NumberFormat(undefined, { style: "currency", currency }).format(value)).join(" · ");
  // Money, else tokens (#838): in the words of the limit it reached.
  const used = !atMoney && atTokens ? `${(agent.tokensToDate ?? 0).toLocaleString()} tokens used.` : `${amount || ""} spent.`;
  const day = atDayTokens ? "The day's token limit has been reached." : "The day's spending limit has been reached.";
  return atAgentLimit || atDayLimit ? <div class="cost-limit" role="status">
      <span>{atAgentLimit ? `This agent reached its cost limit. ${used} Anything you send waits until you allow more.` : `${day} What you send waits here, and goes when the day rolls over.`}</span>
      {atAgentLimit && <button onClick={goOn}>Let this one go on</button>}
    </div> : null;
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
  const refused = (choice: SandboxChoice | undefined) => setBy !== undefined && choice !== "on";
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
