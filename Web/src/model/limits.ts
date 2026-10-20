// Money and token limits (#838), ported from Agent.swift and CostLimits.swift so the
// page reads the same limit as the window and the Remote: whichever is reached first.
import type { Agent, CostLimits, CostState, Cost } from "../protocol/generated";
import { hasTurnInFlight } from "./promptWords";

/** An amount in its currency, as the window's Spending says it. */
export function money(amount: number, currency: string): string {
  try {
    return new Intl.NumberFormat(undefined, { style: "currency", currency }).format(amount);
  } catch {
    return `${amount.toFixed(2)} ${currency}`;
  }
}

/** TurnUsage.limitTokens: fresh input and output, never a cache read. */
export function limitTokens(usage: Agent["lastTurnUsage"]): number {
  if (!usage) return 0;
  const read = usage.cachedReadTokens ?? 0;
  const write = usage.cachedWriteTokens ?? 0;
  const sum = usage.inputTokens + usage.outputTokens;
  const readInside = read > 0 && read <= usage.inputTokens
    && (usage.totalTokens === sum || usage.totalTokens === sum + (usage.thoughtTokens ?? 0));
  const fresh = readInside ? usage.inputTokens - read : usage.inputTokens + write;
  return Math.max(0, fresh) + Math.max(0, usage.outputTokens);
}

/** Agent.costIsUnmeasured. */
export function costIsUnmeasured(agent: Agent): boolean {
  return !hasTurnInFlight(agent) && Object.keys(agent.costToDate ?? {}).length === 0
    && !agent.lastTurnUsage?.cost && !agent.usage?.cost && agent.lastActivityAt > agent.createdAt;
}

/** Agent.tokensAreUnmeasured: its runtime reports no tokens, so no token limit applies. */
export function tokensAreUnmeasured(agent: Agent): boolean {
  return !hasTurnInFlight(agent) && (agent.tokensToDate ?? 0) === 0 && limitTokens(agent.lastTurnUsage) === 0
    && agent.lastActivityAt > agent.createdAt;
}

export function moneyCeiling(agent: Agent, limits: CostLimits | undefined): Cost | undefined {
  return agent.costCeiling ?? limits?.perAgent;
}

export function tokenCeiling(agent: Agent, limits: CostLimits | undefined): number | undefined {
  return agent.tokenCeiling ?? limits?.perAgentTokens;
}

export function isAtMoneyLimit(agent: Agent, limits: CostLimits | undefined): boolean {
  const ceiling = moneyCeiling(agent, limits);
  return !!ceiling && !costIsUnmeasured(agent) && (agent.costToDate?.[ceiling.currency] ?? 0) >= ceiling.amount;
}

export function isAtTokenLimit(agent: Agent, limits: CostLimits | undefined): boolean {
  const ceiling = tokenCeiling(agent, limits);
  return ceiling !== undefined && !tokensAreUnmeasured(agent) && (agent.tokensToDate ?? 0) >= ceiling;
}

/** Agent.tokenFigure: "12,000 of 50,000 tokens", or null when no token limit applies. */
export function tokenFigure(agent: Agent, limits: CostLimits | undefined): string | null {
  const ceiling = tokenCeiling(agent, limits);
  if (ceiling === undefined || tokensAreUnmeasured(agent)) return null;
  return `${(agent.tokensToDate ?? 0).toLocaleString()} of ${ceiling.toLocaleString()} tokens`;
}

/** CostLimits.isDayTokenLimitReached. */
export function dayTokenLimitReached(state: CostState | undefined): boolean {
  const daily = state?.limits.dailyTokens;
  return daily !== undefined && (state?.tokensToday ?? 0) >= daily;
}

/** Agent.goOnRequest: one more step of whichever limit it reached; the other left as it is. */
export function goOnRequest(agent: Agent, limits: CostLimits | undefined): { agentID: string; ceiling?: Cost; tokenCeiling?: number } {
  let ceiling = agent.costCeiling;
  if (isAtMoneyLimit(agent, limits)) {
    const current = moneyCeiling(agent, limits);
    const currency = current?.currency ?? "USD";
    const spent = agent.costToDate?.[currency] ?? 0;
    ceiling = { amount: spent + (current?.amount ?? spent), currency };
  }
  let tokens = agent.tokenCeiling;
  const current = tokenCeiling(agent, limits);
  if (isAtTokenLimit(agent, limits) && current !== undefined) tokens = (agent.tokensToDate ?? 0) + Math.max(current, 1);
  return { agentID: agent.id, ...(ceiling ? { ceiling } : {}), ...(tokens !== undefined ? { tokenCeiling: tokens } : {}) };
}
