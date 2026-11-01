// The line on a choice a policy refuses or caps (#998, spec 998 FR-020): "Set by your organisation"
// (or "Set by you", "Set by this folder": the layer that decided, #3150), and the rule's words in its tip and a detail line. The choice itself is shown,
// dimmed, never hidden. The same as the window's and the Remote's (Shared/UI/OrgPolicyLine.swift).
import type { CostState, PassThroughName, PolicyRefusal, PolicySetBy } from "../protocol/generated";
import type { Store } from "../model/store";
import { budgetFoot, budgetRows, line, markTitle, refusalLine, runtimeName, startsNothing } from "../model/orgPolicy";
import { money } from "../model/limits";
import { StoppedStrip } from "./settings/Policy";

/** Its layer's title (Set by your organisation, you or this folder), with the rule's words under it. Nothing without a mark. */
export function OrgPolicyLine({ mark }: { mark: PolicySetBy | undefined }) {
  if (!mark) return null;
  return (
    <span class="org-policy-line small" title={line(mark)} aria-label={line(mark)}>
      <strong>{markTitle(mark)}</strong> <span>{mark.words}</span>
    </span>
  );
}

/** A refused call's line (policyRefused): its title and words, where a call failed. */
export function OrgPolicyRefusal({ refusal }: { refusal: PolicyRefusal | null | undefined }) {
  if (!refusal) return null;
  return <p class="org-policy-refusal" role="alert">{refusalLine(refusal)}</p>;
}

/** A choice's title with the mark after it, for a native <option>, which can hold only text. */
export function optionLabel(name: string, mark: PolicySetBy | undefined): string {
  return mark ? `${name} (${markTitle(mark)})` : name;
}

/**
 * The red strip on every page (#998, US5 scenario 2): while the organisation has stopped all agent
 * work, as the control plane or any host says it, else a host's own reason to start nothing (no
 * policy it can trust, an update it needs). The window's and the Remote's is OrgPolicyStrip.
 */
export function OrgPolicyStrip({ store }: { store: Store }) {
  const states = Object.values(store.policyStates.value).filter(startsNothing);
  const stopped = store.orgPolicy.value?.policy?.stopAll?.on ? store.orgPolicy.value.policy
    : states.find((s) => s.stopAll && s.policy?.stopAll?.on)?.policy;
  if (stopped) return <StoppedStrip policy={stopped} />;
  const refused = states.find((s) => s.refusal)?.refusal;
  if (!refused) return null;
  return <p class="policy-stopped" role="alert"><strong>{refusalLine(refused)}</strong></p>;
}

/** The organisation's budgets beside the person's own limits on Cost (#998, FR-016): the lower is used. */
export function OrgBudget({ state }: { state: CostState }) {
  const rows = budgetRows(state.organisation, money);
  if (!rows.length) return null;
  return (
    <div class="org-budget">
      {rows.map((r) => <p key={r.name} class="quiet small">{r.title}: {r.words}</p>)}
      <OrgPolicyLine mark={state.setBy ?? { by: "organisation", rule: "budgets", words: budgetFoot }} />
    </div>
  );
}

/** The person's own pass-through names (#998, FR-011a), read only: a name the policy refuses is dimmed, not passed. */
export function PassThroughList({ names }: { names: PassThroughName[] }) {
  if (!names.length) return null;
  return (
    <>
      <h2 class="setup-heading">Variables passed to runtimes</h2>
      <ul class="runtime-list">
        {names.map((n) => (
          <li key={`${n.runtime ?? "*"}/${n.name}`}>
            <p class={n.setBy ? "set-by-org" : undefined}><code>{n.name}</code>{n.runtime && <span class="quiet small"> {runtimeName(n.runtime)}</span>}</p>
            <OrgPolicyLine mark={n.setBy} />
          </li>
        ))}
      </ul>
    </>
  );
}
