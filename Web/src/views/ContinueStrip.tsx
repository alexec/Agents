// A chat paused by a spent allowance (#1859): under its head, Continue at the reset time, or, once
// asked, when it continues and a Cancel, as the window's ContinueWhenBackStrip has them.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { Agent } from "../protocol/generated";
import type { Store } from "../model/store";
import { Capability } from "../protocol/capabilities.generated";
import { continueButton, continueCancelLabel, continuePaused, continueHelp, continueLine, offersContinue, resetsAt } from "../model/continueWhenBack";
import { continueOn } from "../model/levels";
import { go } from "../route";
import { Strip } from "./Strip";

export function ContinueStrip({ store, host, agent, disabled }: { store: Store; host: string; agent: Agent | undefined; disabled: boolean }) {
  // An Auto session's next runtime (#2658, FR-022): its button continues there, by press only.
  const next = useSignal<string | undefined>(undefined);
  const auto = agent?.auto;
  useEffect(() => {
    next.value = undefined;
    if (!agent || !auto) return;
    let current = true;
    void store.autoPreview(host, { cwd: agent.cwd, levels: auto.levels, ...(agent.sandboxOverride ? { sandbox: agent.sandboxOverride } : {}) })
      .then((p) => { if (current) next.value = p?.runtimeID && p.runtimeID !== agent.runtimeID ? p.runtimeID : undefined; });
    return () => { current = false; };
  }, [host, agent?.id, agent?.state]);
  if (!agent || !continueStripApplies(store, host, agent)) return null;
  const line = continueLine(agent);
  const nextName = next.value ? (store.runtimes.value[host] ?? []).find((r) => r.runtime.id === next.value)?.runtime.name ?? next.value : undefined;
  // The allowance's strip (#5034, fourth): grey once asked, as the chat carries on by itself; orange until then.
  return line
    ? <Strip tone="neutral" name="continue-strip" icon="history" line={line}
      second={{ label: continueCancelLabel, disabled, run: () => void store.continueWhenBack(host, agent.id, false) }} />
    : <Strip tone="warning" name="continue-strip" icon="history" line={continuePaused}
      primary={{ label: continueButton(resetsAt(store.runtimeAllowances.value[host], agent.runtimeID)), title: continueHelp, disabled,
        run: () => void store.continueWhenBack(host, agent.id, true) }}
      second={nextName ? { label: continueOn(nextName), disabled, run: () => void store.continueInNew(host, agent.id, true).then((id) => {
        if (id) go({ host, folder: agent.cwd, session: id });
      }) } : null} />;
}

/** Whether the session has an allowance strip: paused by a spent allowance, or asked to continue. */
export function continueStripApplies(store: Store, host: string, agent: Agent | undefined): boolean {
  return !!agent && agent.state !== "archived" && (offersContinue(agent) || !!agent.continueWhenBack)
    && store.has(host, Capability.chatContinueWhenBack1);
}
