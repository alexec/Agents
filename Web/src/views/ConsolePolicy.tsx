// Console ▸ Report Policy (#1804): who sees what in Reports. Each group's leads see its spend and
// time; with Totals Only, without a person or a machine named (Alex, decision 2). A budget a month
// for each group and for the organisation draws a line and a forecast on Reports ▸ Spend.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { Group, ReportPolicy } from "../protocol/generated";
import { budgetInput, budgetValue, failedWords, leadCandidates, orgKey, policyFoot, totalsOnlyFoot } from "../model/console";

export function ReportPolicyPage({ store, down }: { store: Store; down: boolean }) {
  const policy = useSignal<ReportPolicy | null>(null);
  const groups = useSignal<Group[]>([]);
  // The store's one people list (#2055).
  const people = store.people.value?.people ?? [];
  const budgets = useSignal<Record<string, string>>({});
  const problem = useSignal<string | null>(null);
  const saved = useSignal(false);
  const busy = useSignal(false);
  const load = async () => {
    try {
      const [p, g] = await Promise.all([store.link.call("reports/policy", {}), store.link.call("groups/list", {})]);
      policy.value = p;
      groups.value = g.groups;
      budgets.value = Object.fromEntries(Object.entries(p.budgetsUSD).map(([k, v]) => [k, budgetInput(v)]));
      problem.value = null;
    } catch (error) {
      problem.value = failedWords(error);
    }
  };
  const changes = store.peopleChanges.value;
  useEffect(() => { if (!down) void load(); }, [down, changes]);
  const shown = policy.value;
  const change = (next: ReportPolicy) => { policy.value = next; saved.value = false; };
  const setLead = (group: string, user: string, on: boolean) => {
    if (!shown) return;
    const now = (shown.leads[group] ?? []).filter((u) => u !== user);
    change({ ...shown, leads: { ...shown.leads, [group]: on ? [...now, user] : now } });
  };
  const setBudget = (key: string, text: string) => { budgets.value = { ...budgets.value, [key]: text }; saved.value = false; };
  const save = async () => {
    if (!shown) return;
    const budgetsUSD: Record<string, number> = {};
    for (const [key, text] of Object.entries(budgets.value)) {
      const usd = budgetValue(text);
      if (usd === null) { problem.value = `“${text}” is not an amount of dollars.`; return; }
      if (usd > 0) budgetsUSD[key] = usd;
    }
    busy.value = true;
    try {
      policy.value = await store.link.call("reports/setPolicy", { ...shown, budgetsUSD });
      problem.value = null;
      saved.value = true;
    } catch (error) {
      problem.value = failedWords(error);
    } finally {
      busy.value = false;
    }
  };
  const budgetField = (key: string, label: string) => (
    <label class="setting">
      <span>{label}</span>
      <span class="budget-field">$ <input type="text" inputMode="decimal" placeholder="None" aria-label={`${label}, US dollars a month`}
        value={budgets.value[key] ?? ""} onInput={(e) => setBudget(key, (e.currentTarget as HTMLInputElement).value)} /> a month</span>
    </label>
  );
  return (
    <form class="report-policy" onSubmit={(e) => { e.preventDefault(); void save(); }}>
      {problem.value && <p class="hint" role="alert">{problem.value}</p>}
      {!shown && !problem.value && <p class="hint">Loading…</p>}
      {shown && (
        <>
          <section aria-labelledby="policy-leads">
            <h3 class="section-head" id="policy-leads">What Group Leads See</h3>
            <label class="setting">
              <span>Totals only</span>
              <input type="checkbox" role="switch" checked={shown.totalsOnly}
                onChange={(e) => change({ ...shown, totalsOnly: (e.currentTarget as HTMLInputElement).checked })} />
            </label>
            <p class="hint">{totalsOnlyFoot}</p>
          </section>
          <section aria-labelledby="policy-org">
            <h3 class="section-head" id="policy-org">Organisation</h3>
            {budgetField(orgKey, "Budget")}
          </section>
          {groups.value.length === 0 && <p class="hint">No groups yet. Make one in People and Groups.</p>}
          {groups.value.map((g) => (
            <section key={g.id} aria-labelledby={`policy-${g.id}`}>
              <h3 class="section-head" id={`policy-${g.id}`}>{g.name}</h3>
              <fieldset class="group-people">
                <legend>Leads</legend>
                {leadCandidates(g, people).map((p) => (
                  <label key={p.id} class="setting">
                    <span>{p.name}</span>
                    <input type="checkbox" checked={(shown.leads[g.id] ?? []).includes(p.id)}
                      onChange={(e) => setLead(g.id, p.id, (e.currentTarget as HTMLInputElement).checked)} />
                  </label>
                ))}
              </fieldset>
              {budgetField(g.id, "Budget")}
            </section>
          ))}
          <div class="sheet-actions">
            {saved.value && <span class="quiet small" role="status">Saved.</span>}
            <button type="submit" class="prominent" disabled={down || busy.value}>Save</button>
          </div>
          <p class="hint">{policyFoot}</p>
        </>
      )}
    </form>
  );
}
