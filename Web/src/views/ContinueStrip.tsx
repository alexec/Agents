// A chat paused by a spent allowance (#1859): under its head, Continue at the reset time, or, once
// asked, when it continues and a Cancel, as the window's ContinueWhenBackStrip has them.
import type { Agent } from "../protocol/generated";
import type { Store } from "../model/store";
import { Capability } from "../protocol/capabilities.generated";
import { continueButton, continueCancelLabel, continueHelp, continueLine, offersContinue, resetsAt } from "../model/continueWhenBack";

export function ContinueStrip({ store, host, agent, disabled }: { store: Store; host: string; agent: Agent | undefined; disabled: boolean }) {
  if (!agent || !(offersContinue(agent) || agent.continueWhenBack) || !store.has(host, Capability.chatContinueWhenBack1)) return null;
  const line = continueLine(agent);
  return (
    <div class="continue-strip" role="status">
      {line && <span class="what">{line}</span>}
      {line
        ? <button disabled={disabled} onClick={() => void store.continueWhenBack(host, agent.id, false)}>{continueCancelLabel}</button>
        : <button disabled={disabled} title={continueHelp} onClick={() => void store.continueWhenBack(host, agent.id, true)}>
          ↻ {continueButton(resetsAt(store.runtimeAllowances.value[host], agent.runtimeID))}</button>}
    </div>
  );
}
