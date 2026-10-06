import type { Agent, CostState, SandboxChoice } from "../protocol/generated";
import { sandboxChoices, sandboxExplanation, sandboxState, sandboxStateWords, sandboxWhy } from "../model/sandbox";

export function CostLimitBanner({ agent, costs, goOn }: { agent: Agent; costs: CostState | undefined; goOn: () => void }) {
  const limits = costs?.limits;
  const ceiling = agent.costCeiling ?? limits?.perAgent;
  const spent = ceiling ? (agent.costToDate?.[ceiling.currency] ?? 0) : 0;
  const atAgentLimit = !!ceiling && spent >= ceiling.amount;
  const atDayLimit = !!limits?.daily && (costs?.today?.[limits.daily.currency] ?? 0) >= limits.daily.amount;
  const amount = Object.entries(agent.costToDate ?? {}).sort(([a], [b]) => a.localeCompare(b))
    .map(([currency, value]) => new Intl.NumberFormat(undefined, { style: "currency", currency }).format(value)).join(" · ");
  return atAgentLimit || atDayLimit ? <div class="cost-limit" role="status">
      <span>{atAgentLimit ? `This agent reached its cost limit. ${amount || ""} spent. Anything you send waits until you allow more.` : "The day's spending limit has been reached. What you send waits here, and goes when the day rolls over."}</span>
      {atAgentLimit && <button onClick={goOn}>Let this one go on</button>}
    </div> : null;
}

export function ContextMeter({ agent }: { agent: Agent }) {
  const usage = agent.usage;
  const fraction = usage && usage.size > 0 ? Math.min(1, usage.used / usage.size) : undefined;
  const amounts = Object.entries(agent.costToDate ?? {}).sort(([a], [b]) => a.localeCompare(b))
    .map(([currency, value]) => new Intl.NumberFormat(undefined, { style: "currency", currency }).format(value)).join(" · ");
  const cost = amounts || (usage?.cost ? new Intl.NumberFormat(undefined, { style: "currency", currency: usage.cost.currency }).format(usage.cost.amount)
    : ["starting", "running", "waitingOnUser"].includes(agent.state) ? "$0.00" : "Not measured");
  return <span class="context-meter" title={fraction === undefined ? "Cost reported by the runtime" : `${usage!.used.toLocaleString()} of ${usage!.size.toLocaleString()} tokens`}>
    {fraction !== undefined && <span class={`context-ring${fraction >= .85 ? " close" : ""}`} style={{ "--used": `${fraction * 100}%` }} aria-label={`${Math.round(fraction * 100)}% context used`} />}
    {cost}
  </span>;
}

export function SandboxCapsule({ runtimeID, override, runtimeDefault = "runtime", mode, onChange, disabled = false }: {
  runtimeID: string; override?: SandboxChoice | undefined; runtimeDefault?: SandboxChoice | undefined; mode?: string | undefined;
  onChange?: ((choice: SandboxChoice | undefined) => void) | undefined; disabled?: boolean | undefined;
}) {
  const state = sandboxState(runtimeID, override ?? runtimeDefault, mode);
  const choices = sandboxChoices(runtimeID);
  const why = sandboxWhy(runtimeID);
  if (!choices.length || !onChange) return <span class="pill quiet" title={why ?? sandboxStateWords(state)}>{sandboxStateWords(state)}</span>;
  return <label class="pill select" title={sandboxExplanation(override ?? runtimeDefault, runtimeID, runtimeID)}>
    <span aria-hidden="true">{sandboxStateWords(state)} ▾</span>
    <select aria-label="Command sandbox" disabled={disabled} value={override ?? ""} onChange={(e) => {
      const value = (e.currentTarget as HTMLSelectElement).value;
      onChange(value ? value as SandboxChoice : undefined);
    }}>
      <option value="">Use runtime default</option>
      {choices.map((choice) => <option key={choice} value={choice}>{choice === "runtime" ? "As configured by runtime" : choice === "on" ? "On" : "Off"}</option>)}
    </select>
  </label>;
}
