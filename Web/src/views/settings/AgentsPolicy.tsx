// Settings ▸ Agents ▸ Policy (#2957, FR-019 to FR-021, frames A and C): your layer of the policy, in five sections,
// each row with your value, its cap from a layer above with 🔒 and the line that names that layer, "Kept, not used"
// when your value is capped, and Where this comes from. The machine resolves the layers (policy/effective) and keeps
// your layer on the Mac's host (policy/yours, policy/setYours). The window's is Shared/UI/PolicyPane.swift. Listed
// in ./sections.ts.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../../model/store";
import type { EffectivePolicy, EffectiveRule, JSONValue, YourPolicyState } from "../../protocol/generated";
import { describe } from "../../model/errors";
import {
  banner, behindLine, choice, count, foldersLine, foot, isLooser, keptNotUsed, moneyValue, notSet, organisationTitle, rowsIn,
  sections, sectionTitles, setting, title, tokensValue, toolsFoot, ruleValue, whereFrom, yoursIsKept, type Row,
} from "../../model/policyLayers";
import { PolicySource } from "./PolicySource";

export function AgentsPolicySection({ store, down }: { store: Store; down: boolean }) {
  const effective = useSignal<EffectivePolicy | null>(null);
  const yours = useSignal<YourPolicyState | null>(null);
  const problem = useSignal<string | null>(null);
  const saving = useSignal(false);
  const host = store.macHostID.value;
  const load = async () => {
    try {
      effective.value = await store.link.call("policy/effective", {}, host);
      yours.value = await store.link.call("policy/yours", {}, host);
      problem.value = null;
    } catch (error) {
      problem.value = describe(error);
    }
  };
  const changes = store.policyChanges.value;
  useEffect(() => { if (!down) void load(); }, [down, host, changes]);
  const save = async (rule: string, value: JSONValue | undefined) => {
    const kept = yours.value;
    if (!kept) return;
    saving.value = true;
    try {
      await store.link.call("policy/setYours", { rules: setting(kept.policy.rules, rule, value), revision: kept.policy.revision }, host);
      problem.value = null;
    } catch (error) {
      problem.value = describe(error);
    } finally {
      saving.value = false;
    }
    await load();
  };
  const eff = effective.value;
  return (
    <section aria-labelledby="settings-agents-policy">
      <h3 class="section-head" id="settings-agents-policy">{title}</h3>
      {!eff && !problem.value && <p class="hint">Loading…</p>}
      {problem.value && <p class="hint" role="alert">{problem.value}</p>}
      {eff && (
        <>
          <div class="policy-banner">
            <p class="strong">{banner(eff)}</p>
            {eff.organisation
              // The Organisation Policy section of this page, below in Control plane.
              ? <button type="button" class="link" onClick={() => document.getElementById("settings-policy")?.scrollIntoView()}>{organisationTitle}</button>
              : <p class="hint">{foldersLine(eff.foldersWithRules.length)}</p>}
            {behindLine(eff.behind) && <p class="hint" role="status">{behindLine(eff.behind)}</p>}
          </div>
          {sections.map((section) => (
            <div key={section} class="policy-section">
              <h4 class="section-head">{sectionTitles[section]}</h4>
              {rowsIn(section).map((row) => (
                <RuleRow key={row.rule} row={row} rule={eff.rules.find((r) => r.rule === row.rule)}
                  yours={yours.value ? ruleValue(yours.value.policy.rules, row.rule) : undefined}
                  editable={!down && yours.value !== null && !saving.value} set={(v) => void save(row.rule, v)} />
              ))}
              {section === "tools" && <p class="hint">{toolsFoot}</p>}
            </div>
          ))}
          <p class="hint">{foot}</p>
        </>
      )}
    </section>
  );
}

function RuleRow({ row, rule, yours, editable, set }: { row: Row; rule: EffectiveRule | undefined; yours: JSONValue | undefined;
  editable: boolean; set: (value: JSONValue | undefined) => void }) {
  const open = useSignal(false);
  const id = `policy-${row.rule.replace(".", "-")}`;
  return (
    <div class="policy-rule">
      <label class="setting" for={id}>
        <span>{row.title}</span>
        <Control id={id} row={row} rule={rule} yours={yours} editable={editable} set={set} />
      </label>
      {rule?.capLine && <p class="hint"><span aria-hidden="true">🔒 </span>{rule.capLine}</p>}
      {rule && yoursIsKept(rule) && <p class="hint">{keptNotUsed}. {rule.words} applies.</p>}
      <button type="button" class="link small" aria-expanded={open.value} disabled={!rule} onClick={() => { open.value = !open.value; }}>
        {whereFrom}
      </button>
      {open.value && rule && <PolicySource row={row} rule={rule} />}
    </div>
  );
}

function Control({ id, row, rule, yours, editable, set }: { id: string; row: Row; rule: EffectiveRule | undefined;
  yours: JSONValue | undefined; editable: boolean; set: (value: JSONValue | undefined) => void }) {
  const unset = `${notSet} (${row.unset})`;
  switch (row.kind.kind) {
    case "choice":
    case "count": {
      const values: JSONValue[] = row.kind.kind === "choice" ? row.kind.order : row.kind.numbers;
      const all = typeof yours === "number" && !values.includes(yours) ? [...values, yours].sort((a, b) => Number(a) - Number(b)) : values;
      const words = (v: JSONValue) => row.kind.kind === "choice" ? choice(row.rule, String(v)) : count(row.rule, Number(v));
      return (
        <select id={id} disabled={!editable} value={yours === undefined ? "" : String(yours)}
          onChange={(e) => {
            const raw = e.currentTarget.value;
            set(raw === "" ? undefined : row.kind.kind === "count" ? Number(raw) : raw);
          }}>
          <option value="">{unset}</option>
          {all.map((v) => {
            const looser = isLooser(row, v, rule?.cap);
            // The reason on a dimmed value, but not on your own, whose cap line is under the row.
            const reason = looser && rule?.capLine && v !== yours ? ` — ${rule.capLine}` : "";
            return <option key={String(v)} value={String(v)} disabled={looser}>{words(v)}{reason}</option>;
          })}
        </select>
      );
    }
    case "money":
    case "tokens": {
      const money = row.kind.kind === "money";
      const shown = yours === undefined ? "" : money ? String((yours as { amount: number }).amount) : String(yours);
      return (
        <input id={id} type="text" inputMode="decimal" placeholder="No limit" disabled={!editable} value={shown}
          onChange={(e) => {
            const v = money ? moneyValue(e.currentTarget.value) : tokensValue(e.currentTarget.value);
            if (v !== null) set(v);
          }} />
      );
    }
    case "toggle":
      return <input id={id} type="checkbox" role="switch" disabled={!editable} checked={yours !== false}
        onChange={(e) => set(e.currentTarget.checked)} />;
    case "list":
      return <span id={id} class="quiet">{rule?.decides ? rule.words : row.unset}</span>;
  }
}
