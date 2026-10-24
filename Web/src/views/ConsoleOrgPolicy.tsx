// Console ▸ Policy (#998, spec 998 FR-023): the organisation's one policy, which every machine follows as a
// ceiling over the person's and the folder's own settings. A control per rule, what the change does before
// it is saved (the rules that change, and what they refuse), and Save with the tag that was read, so that
// two admins saving at once are told. The kill switch is here as well as in every client's Settings ▸ Policy.
//
// Edits not saved are kept while another page is open, as Report Policy keeps them (#2072).
import { useEffect } from "preact/hooks";
import { signal, useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { FleetMachine, OrgRouteKept, PolicyKept } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { failedWords, notSaved } from "../model/console";
import { changed, changes, formOf, modeNames, modes, policyOf, reachChoiceNames, reachChoices, runtimeName, termsChoices, termsNames, unmetered, viewOf,
  warnings } from "../model/orgPolicy";
import type { ReachChoice } from "../model/orgPolicy";
import { routeRuntimes } from "../model/orgAccounts";
import type { ModeName, PolicyForm } from "../model/orgPolicy";
import { KillSwitch, StoppedStrip } from "./settings/Policy";

interface Draft {
  store: Store;
  form: PolicyForm;
}
const draft = signal<Draft | null>(null);

addEventListener("beforeunload", (e) => {
  if (!draft.value) return;
  e.preventDefault();
  e.returnValue = "";
});

/** Whether the store's control plane has Policy edits not saved, for the Console's list. */
export function orgPolicyNotSaved(store: Store): boolean {
  return draft.value?.store === store;
}

export const orgPolicyFoot = "Every machine follows the policy within seconds, and keeps it offline. A rule only caps a person’s or a folder’s own setting: it comes back when the rule does. Budgets are for each person, per UTC day.";

export function OrgPolicyPage({ store, down }: { store: Store; down: boolean }) {
  const kept = useSignal<PolicyKept | null>(null);
  const machines = useSignal<FleetMachine[] | undefined>(undefined);
  // The org routes, for the warning when the org path has no route (#999); none from a control plane before them.
  const routes = useSignal<OrgRouteKept[] | undefined>(undefined);
  const problem = useSignal<string | null>(null);
  const saved = useSignal(false);
  const busy = useSignal(false);
  const load = async () => {
    try {
      const [k, fleet, list] = await Promise.all([store.link.call("policy/get", {}),
        store.link.call("console/fleet", {}).catch(() => null), store.link.call("orgRoutes/list", {}).catch(() => null)]);
      kept.value = k;
      machines.value = fleet?.machines;
      routes.value = list?.routes;
      problem.value = null;
    } catch (error) {
      problem.value = failedWords(error);
    }
  };
  // Again when another admin saves it, or the kill switch moves.
  const view = store.orgPolicy.value;
  const routeChanges = store.orgRoutesChanges.value;
  useEffect(() => { if (!down) void load(); }, [down, view, routeChanges]);
  const loaded = kept.value?.policy;
  const edits = draft.value?.store === store ? draft.value : null;
  const form = edits?.form ?? (kept.value ? formOf(loaded) : null);
  const person = store.person.value;
  const me = person ? { user: person.id, userName: person.name } : { user: "" };
  const made = form ? policyOf(form, loaded, me) : null;
  const next = made && "policy" in made ? made.policy : null;
  const edit = (change: Partial<PolicyForm>) => {
    if (!form) return;
    draft.value = { store, form: { ...form, ...change } };
    saved.value = false;
  };
  const save = async () => {
    if (!made) return;
    if ("problem" in made) { problem.value = made.problem; return; }
    const warned = warnings(made.policy, machines.value, routes.value?.map((r) => r.route));
    if (warned.some((w) => w.includes("nobody can start an agent")) && !window.confirm(`${warned.join("\n")}\n\nSave the policy anyway?`)) return;
    busy.value = true;
    try {
      const rev = kept.value?.rev;
      kept.value = await store.link.call("policy/set", rev === undefined ? { policy: made.policy } : { policy: made.policy, rev });
      store.orgPolicy.value = viewOf(kept.value.policy);
      draft.value = null;
      problem.value = null;
      saved.value = true;
    } catch (error) {
      problem.value = failedWords(error);
    } finally {
      busy.value = false;
    }
  };
  if (!form) return problem.value ? <p class="hint" role="alert">{problem.value}</p> : <p class="hint">Loading…</p>;
  const preview = edits && next ? changes(loaded, next) : [];
  const warned = next ? warnings(next, machines.value, routes.value?.map((r) => r.route)) : [];
  const text = (key: keyof PolicyForm) => (e: Event) => edit({ [key]: (e.currentTarget as HTMLInputElement).value });
  const check = (key: keyof PolicyForm) => (e: Event) => edit({ [key]: (e.currentTarget as HTMLInputElement).checked });
  const budgetSet = [form.daily, form.dailyTokens, form.perAgent, form.perAgentTokens].some((t) => t.trim() !== "");
  return (
    <form class="org-policy" onSubmit={(e) => { e.preventDefault(); void save(); }}>
      {problem.value && <p class="hint" role="alert">{problem.value}</p>}
      <StoppedStrip policy={loaded} />
      {loaded ? <p class="quiet small">{changed(loaded, fromWireDate(loaded.issued), new Date())}</p>
        : <p class="quiet small">No policy yet. Nothing is capped until you save one.</p>}

      <section aria-labelledby="org-policy-modes">
        <h3 class="section-head" id="org-policy-modes">Modes and Sandbox</h3>
        <label class="setting">
          <span>Loosest mode</span>
          <select value={form.mode} onChange={(e) => edit({ mode: (e.currentTarget as HTMLSelectElement).value as ModeName | "" })}>
            <option value="">Any</option>
            {modes.map((m) => <option key={m} value={m}>Up to {modeNames[m]}</option>)}
          </select>
        </label>
        <label class="setting">
          <span>Require the command sandbox</span>
          <input type="checkbox" role="switch" checked={form.sandboxRequired} onChange={check("sandboxRequired")} />
        </label>
      </section>

      <section aria-labelledby="org-policy-runtimes">
        <h3 class="section-head" id="org-policy-runtimes">Runtimes</h3>
        <label class="setting">
          <span>Allow only the runtimes chosen</span>
          <input type="checkbox" role="switch" checked={form.limitRuntimes} onChange={check("limitRuntimes")} />
        </label>
        {form.limitRuntimes && Object.keys(form.runtimes).sort((a, b) => runtimeName(a).localeCompare(runtimeName(b))).map((id) => {
          const field = form.runtimes[id]!;
          const set = (change: Partial<typeof field>) => edit({ runtimes: { ...form.runtimes, [id]: { ...field, ...change } } });
          return (
            <div key={id} class="setting">
              <label><input type="checkbox" checked={field.on} onChange={(e) => set({ on: (e.currentTarget as HTMLInputElement).checked })} /> {runtimeName(id)}</label>
              {field.on && <input type="text" class="runtime-models" placeholder="Every model" aria-label={`${runtimeName(id)} models`}
                value={field.models} onInput={(e) => set({ models: (e.currentTarget as HTMLInputElement).value })} />}
            </div>
          );
        })}
        {form.limitRuntimes && <p class="hint">Models by id, commas between, with * at the end allowed (claude-sonnet-*). Empty allows every model.</p>}
      </section>

      <section aria-labelledby="org-policy-reach">
        <h3 class="section-head" id="org-policy-reach">Ways to the Model</h3>
        {routeRuntimes.map((id) => (
          <label key={id} class="setting">
            <span>{runtimeName(id)} reaches the model by</span>
            <select aria-label={`${runtimeName(id)} reaches the model by`} value={form.reach[id] ?? "any"}
              onChange={(e) => edit({ reach: { ...form.reach, [id]: (e.currentTarget as HTMLSelectElement).value as ReachChoice } })}>
              {reachChoices.map((c) => <option key={c} value={c}>{reachChoiceNames[c]}</option>)}
            </select>
          </label>
        ))}
        <p class="hint">Org key or gateway only refuses each member’s own sign-in, and their own key or gateway in the variables passed to the runtime. Add the routes in Model Access.</p>
        <label class="setting">
          <span>Antigravity’s terms</span>
          <select aria-label="Antigravity’s terms" value={form.antigravityTerms}
            onChange={(e) => edit({ antigravityTerms: (e.currentTarget as HTMLSelectElement).value as (typeof termsChoices)[number] })}>
            {termsChoices.map((c) => <option key={c} value={c}>{termsNames[c]}</option>)}
          </select>
        </label>
        <p class="hint">Reviewed by your organisation: members do not see Google’s notice. Do not allow: Antigravity is refused.</p>
      </section>

      <section aria-labelledby="org-policy-marketplaces">
        <h3 class="section-head" id="org-policy-marketplaces">Marketplaces</h3>
        <label class="setting">
          <span>Allow only the marketplaces named</span>
          <input type="checkbox" role="switch" checked={form.limitMarketplaces} onChange={check("limitMarketplaces")} />
        </label>
        {form.limitMarketplaces && (
          <>
            <input type="text" class="wide" placeholder="Marketplace ids, commas between" aria-label="Marketplaces allowed"
              value={form.marketplaces} onInput={text("marketplaces")} />
            <label class="setting">
              <span>Refuse MCP servers added by hand</span>
              <input type="checkbox" role="switch" checked={form.refuseCustomServers} onChange={check("refuseCustomServers")} />
            </label>
          </>
        )}
      </section>

      <section aria-labelledby="org-policy-budget">
        <h3 class="section-head" id="org-policy-budget">Budget for Each Person</h3>
        {([["daily", "A day", "$"], ["dailyTokens", "Tokens a day", ""], ["perAgent", "An agent", "$"], ["perAgentTokens", "Tokens an agent", ""]] as const)
          .map(([key, label, unit]) => (
            <label key={key} class="setting">
              <span>{label}</span>
              <span class="budget-field">{unit} <input type="text" inputMode="decimal" placeholder="None" aria-label={label}
                value={form[key]} onInput={text(key)} /></span>
            </label>
          ))}
        {budgetSet && (
          <fieldset class="group-people">
            <legend>Allow unmetered runtimes</legend>
            {[...unmetered].sort((a, b) => runtimeName(a).localeCompare(runtimeName(b))).map((id) => (
              <label key={id} class="setting">
                <span>{runtimeName(id)}</span>
                <input type="checkbox" checked={form.allowUnmetered.includes(id)}
                  onChange={(e) => edit({ allowUnmetered: (e.currentTarget as HTMLInputElement).checked
                    ? [...form.allowUnmetered, id] : form.allowUnmetered.filter((x) => x !== id) })} />
              </label>
            ))}
          </fieldset>
        )}
        <p class="hint">A runtime that reports tokens and no cost, such as one on a subscription, counts against the token budget. One that reports neither is refused under a budget unless you allow it.</p>
      </section>

      <section aria-labelledby="org-policy-helpers">
        <h3 class="section-head" id="org-policy-helpers">Helper Sessions in a Folder</h3>
        <label class="setting">
          <span>Most running</span>
          <span class="budget-field"><input type="text" inputMode="numeric" placeholder="None" aria-label="Most running" value={form.mostRunning} onInput={text("mostRunning")} /></span>
        </label>
        <label class="setting">
          <span>Most not archived</span>
          <span class="budget-field"><input type="text" inputMode="numeric" placeholder="None" aria-label="Most not archived" value={form.mostNotArchived} onInput={text("mostNotArchived")} /></span>
        </label>
      </section>

      <section aria-labelledby="org-policy-environment">
        <h3 class="section-head" id="org-policy-environment">Variables Passed to Runtimes</h3>
        <label class="setting">
          <span>Allow only the variables named</span>
          <input type="checkbox" role="switch" checked={form.limitPassThrough} onChange={check("limitPassThrough")} />
        </label>
        {form.limitPassThrough && <input type="text" class="wide" placeholder="ANTHROPIC_*, OPENAI_API_KEY" aria-label="Variables allowed"
          value={form.passThrough} onInput={text("passThrough")} />}
      </section>

      <section aria-labelledby="org-policy-machines">
        <h3 class="section-head" id="org-policy-machines">Machines</h3>
        <label class="setting">
          <span>Refuse agents on machines that do not follow the policy</span>
          <input type="checkbox" role="switch" checked={form.requireFollowing} onChange={check("requireFollowing")} />
        </label>
      </section>

      {(preview.length > 0 || warned.length > 0) && (
        <section aria-labelledby="org-policy-preview">
          <h3 class="section-head" id="org-policy-preview">What Changes</h3>
          {preview.length > 0 && <ul class="preview">{preview.map((p) => <li key={p}>{p}</li>)}</ul>}
          {warned.map((w) => <p key={w} class="hint attention">{w}</p>)}
        </section>
      )}

      <div class="sheet-actions">
        {edits ? <span class="quiet small attention" role="status">{notSaved}</span>
          : saved.value && <span class="quiet small" role="status">Saved. Every machine has it within seconds.</span>}
        {edits && <button type="button" disabled={busy.value} onClick={() => { draft.value = null; }}>Revert</button>}
        <button type="submit" class="prominent" disabled={down || busy.value || !edits}>Save</button>
      </div>

      <section aria-labelledby="org-policy-stop">
        <h3 class="section-head" id="org-policy-stop">Stop All Agent Work</h3>
        <KillSwitch store={store} policy={loaded} down={down}
          changedTo={() => void load()} />
      </section>
      <p class="hint">{orgPolicyFoot}</p>
    </form>
  );
}
