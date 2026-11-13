// Settings ▸ Agents ▸ Policy (#2957, FR-019 to FR-021, frames A and C): your layer of the policy, in five sections,
// each row with your value, its cap from a layer above with 🔒 and the line that names that layer, "Kept, not used"
// when your value is capped, and Where this comes from. The machine resolves the layers (policy/effective) and keeps
// your layer on the Mac's host (policy/yours, policy/setYours). The window's is Shared/UI/PolicyPane.swift. Listed
// in ./sections.ts.
// A folder's layer opens in the same pane (T057, research R13; FR-022), from the banner's list of folders with their
// own rules or any folder of the Mac's: each row starts "Same as yours" with your value, and a value above yours is
// "Capped by yours" (policy/folder, policy/setFolder). The route's item names it: #/settings/settings/policy:<folder>.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../../model/store";
import type {
  EffectivePolicy, EffectiveRule, JSONValue, PolicyFolderState, PolicyFolderWithRules, UntrustedYourPolicy, URLString, YourPolicyState,
} from "../../protocol/generated";
import { describe } from "../../model/errors";
import { absolutePath } from "../../model/fileWatch";
import {
  backToYours, banner, behindLine, cappedByYours, choice, count, folderFile, folderIsKept, folderName, foldersLine, folderWaits, foot,
  isLooser, keptNotUsed, layerLine, moneyValue, notSet, openFolder, organisationItem, organisationTitle, policyFolderOf, policyItem,
  rowsIn, rulesCount, sameAsYoursLine, sections, sectionTitles, setAside, setting, signAgain, title, tokensValue, toolsFoot, ruleValue,
  untrustedLine, untrustedNone, untrustedRule, untrustedTitle, whereFrom, yoursIsKept, type Row,
} from "../../model/policyLayers";
import { go, route } from "../../route";
import { PolicySource } from "./PolicySource";
import { GuardedChangeCard } from "../GuardedChange";
import { useSettingsMachine } from "./SettingsMachine";
import { MessageBanner } from "../MessageKinds";
import { Icon } from "../Icon";

export function AgentsPolicySection({ store, down }: { store: Store; down: boolean }) {
  const item = route.value.nav === "settings" ? route.value.item : undefined;
  const folder = policyFolderOf(item);
  // A Stopped by a policy card's Change or See Organisation Policy opens Settings at its section.
  useEffect(() => {
    const id = item === organisationItem ? "settings-policy" : item?.startsWith("policy") ? "settings-agents-policy" : undefined;
    if (id) document.getElementById(id)?.scrollIntoView();
  }, [item]);
  const { host, picker } = useSettingsMachine(store);
  return (
    <section aria-labelledby="settings-agents-policy">
      <h3 class="section-head" id="settings-agents-policy">{title}</h3>
      {picker}
      {host && <Layer key={`${host}|${folder ?? ""}`} store={store} host={host} down={down} folder={folder} />}
    </section>
  );
}

/** Your layer, or a folder's when folder is set. */
function Layer({ store, host, down, folder }: { store: Store; host: string; down: boolean; folder: string | undefined }) {
  const effective = useSignal<EffectivePolicy | null>(null);
  const yours = useSignal<YourPolicyState | null>(null);
  const folderState = useSignal<PolicyFolderState | null>(null);
  const problem = useSignal<string | null>(null);
  const saving = useSignal(false);
  const load = async () => {
    try {
      if (folder === undefined) {
        effective.value = await store.link.call("policy/effective", {}, host);
        yours.value = await store.link.call("policy/yours", {}, host);
      } else {
        effective.value = await store.link.call("policy/effective", { folder: folder as URLString }, host);
        folderState.value = await store.link.call("policy/folder", { folder: folder as URLString }, host);
      }
      problem.value = null;
    } catch (error) {
      problem.value = describe(error);
    }
  };
  const changes = store.policyChanges.value;
  useEffect(() => { if (!down) void load(); }, [down, host, changes]);
  // The rules this layer sets, and nothing else (FR-014).
  const own = folder === undefined ? yours.value?.policy.rules : folderState.value?.rules;
  const save = async (rule: string, value: JSONValue | undefined) => {
    const kept = yours.value;
    if (!own || (folder === undefined && !kept)) return;
    saving.value = true;
    try {
      if (folder === undefined) {
        await store.link.call("policy/setYours", { rules: setting(own, rule, value), revision: kept!.policy.revision }, host);
      } else {
        await store.link.call("policy/setFolder", { folder: folder as URLString, rules: setting(own, rule, value) }, host);
      }
      problem.value = null;
    } catch (error) {
      problem.value = describe(error);
    } finally {
      saving.value = false;
    }
    await load();
  };
  // A copy of your layer signed on another Mac (#3230): its rules apply only once the person signs them here.
  const settle = async (sign: boolean) => {
    const kept = yours.value;
    const copy = kept?.untrusted;
    if (!kept || !copy) return;
    saving.value = true;
    try {
      await store.link.call("policy/settleUntrustedYours", { file: copy.file, revision: kept.policy.revision, sign }, host);
      problem.value = null;
    } catch (error) {
      problem.value = describe(error);
    } finally {
      saving.value = false;
    }
    await load();
  };
  const eff = effective.value;
  const pending = folderState.value?.pending;
  const invalid = folderState.value?.invalid;
  return (
    <>
      {!eff && !problem.value && <p class="hint">Loading…</p>}
      {problem.value && <MessageBanner tone="failure">{problem.value}</MessageBanner>}
      {eff && (
        <>
          {folder === undefined ? (
            <MessageBanner tone="neutral" name="policy-banner">
              <p class="strong">{banner(eff)}</p>
              {eff.organisation && (
                // The Organisation Policy section of this page, below in Control plane.
                <button type="button" class="link" onClick={() => document.getElementById("settings-policy")?.scrollIntoView()}>{organisationTitle}</button>
              )}
              <FolderList store={store} host={host} folders={eff.foldersWithRules} />
              {behindLine(eff.behind) && <p class="hint" role="status">{behindLine(eff.behind)}</p>}
            </MessageBanner>
          ) : (
            <MessageBanner tone="neutral" name="policy-banner">
              <button type="button" class="link" onClick={() => go({ nav: "settings", section: "settings", item: policyItem() })}>{backToYours}</button>
              <p class="strong">{layerLine({ kind: "folder", name: folderName(folder), folder })}</p>
              <p class="hint">{folderFile}</p>
              {pending && <p class="hint" role="status">{invalid ?? folderWaits}</p>}
            </MessageBanner>
          )}
          {folder === undefined && yours.value?.untrusted && (
            <Untrusted copy={yours.value.untrusted} busy={down || saving.value} settle={(sign) => void settle(sign)} />
          )}
          {folder !== undefined && pending && (
            // The waiting change itself (frame D): Allow, Keep <old value>, Show Change.
            <div class="cards">
              <GuardedChangeCard store={store} host={host} change={pending} down={down}
                folder={(store.folders.value[host] ?? []).find((f) => absolutePath(f.folder.folder) === absolutePath(folder))?.folder.folder ?? folder} />
            </div>
          )}
          {sections.map((section) => (
            <div key={section} class="policy-section">
              <h4 class="section-head">{sectionTitles[section]}</h4>
              {rowsIn(section).map((row) => (
                <RuleRow key={row.rule} row={row} rule={eff.rules.find((r) => r.rule === row.rule)} folder={folder !== undefined}
                  yours={own ? ruleValue(own, row.rule) : undefined}
                  editable={!down && own !== undefined && !saving.value} set={(v) => void save(row.rule, v)} />
              ))}
              {section === "tools" && <p class="hint">{toolsFoot}</p>}
            </div>
          ))}
          <p class="hint">{foot}</p>
        </>
      )}
    </>
  );
}

/** The rules of a copy of your layer this Mac can't trust (#3230), and the person's choice: sign them with this Mac's
 * person key, or set the copy aside. Nothing signs them without it. */
function Untrusted({ copy, busy, settle }: { copy: UntrustedYourPolicy; busy: boolean; settle: (sign: boolean) => void }) {
  return (
    // Attention (docs/reference/design-system.md, "Messages"): only the person can sign them or set them aside.
    <MessageBanner tone="attention" name="policy-banner policy-untrusted">
      <p class="strong">{untrustedTitle}</p>
      <p class="hint">{untrustedLine(copy)}</p>
      {copy.lines.length === 0 ? <p class="hint">{untrustedNone}</p> : (
        <ul class="policy-untrusted-rules">
          {copy.lines.map((line) => <li key={line.rule}>{untrustedRule(line)}</li>)}
        </ul>
      )}
      <div class="policy-untrusted-actions">
        <button type="button" class="prominent" disabled={busy} onClick={() => settle(true)}>{signAgain}</button>
        <button type="button" disabled={busy} onClick={() => settle(false)}>{setAside}</button>
      </div>
    </MessageBanner>
  );
}

/** The banner's "<n> folders have their own rules" (R13): opens the list, each folder to its layer, and a menu of the
 * Mac's other folders, to open one that sets nothing yet. */
function FolderList({ store, host, folders }: { store: Store; host: string; folders: PolicyFolderWithRules[] }) {
  const open = useSignal(false);
  const show = (folder: string) => go({ nav: "settings", section: "settings", item: policyItem(folder) });
  const listed = new Set(folders.map((f) => absolutePath(f.folder)));
  const others = (store.folders.value[host] ?? [])
    .filter((s) => s.exists && !s.folder.archivedAt && !listed.has(absolutePath(s.folder.folder)))
    .sort((a, b) => a.name.localeCompare(b.name));
  return (
    <>
      <button type="button" class="link" aria-expanded={open.value} onClick={() => { open.value = !open.value; }}>
        {foldersLine(folders.length)}
      </button>
      {open.value && (
        <>
          {folders.length > 0 && (
            <ul class="policy-folders">
              {folders.map((f) => (
                <li key={f.folder}>
                  <button type="button" class="link" onClick={() => show(f.folder)}>{f.name}</button>
                  {" "}<span class="quiet small">{rulesCount(f.count)}</span>
                </li>
              ))}
            </ul>
          )}
          {others.length > 0 && (
            <select aria-label={openFolder} value="" onChange={(e) => { const v = e.currentTarget.value; if (v) show(v); }}>
              <option value="">{openFolder}</option>
              {others.map((s) => <option key={s.folder.folder} value={absolutePath(s.folder.folder)}>{s.name}</option>)}
            </select>
          )}
        </>
      )}
    </>
  );
}

function RuleRow({ row, rule, folder, yours, editable, set }: { row: Row; rule: EffectiveRule | undefined; folder: boolean;
  yours: JSONValue | undefined; editable: boolean; set: (value: JSONValue | undefined) => void }) {
  const open = useSignal(false);
  const id = `policy-${row.rule.replace(".", "-")}`;
  // Your value under a cap is kept, not used (FR-006); a folder's value above yours is capped by yours (US3 scenario 6).
  const kept = rule && (folder ? folderIsKept(rule) : yoursIsKept(rule));
  return (
    <div class="policy-rule">
      <label class="setting" for={id}>
        <span>{row.title}</span>
        <Control id={id} row={row} rule={rule} folder={folder} yours={yours} editable={editable} set={set} />
      </label>
      {rule?.capLine && <p class="hint"><Icon name="lock" />{" "}{rule.capLine}</p>}
      {rule && kept && <p class="hint">{folder ? cappedByYours : keptNotUsed}. {rule.words} applies.</p>}
      <button type="button" class="link small" aria-expanded={open.value} disabled={!rule} onClick={() => { open.value = !open.value; }}>
        {whereFrom}
      </button>
      {open.value && rule && <PolicySource row={row} rule={rule} />}
    </div>
  );
}

function Control({ id, row, rule, folder, yours, editable, set }: { id: string; row: Row; rule: EffectiveRule | undefined;
  folder: boolean; yours: JSONValue | undefined; editable: boolean; set: (value: JSONValue | undefined) => void }) {
  // A folder row that sets nothing gets your value (FR-022).
  const unset = folder ? sameAsYoursLine(row, rule) : `${notSet} (${row.unset})`;
  // The reason on a dimmed value, but not on the layer's own, whose cap line is under the row.
  const reason = (v: JSONValue) => isLooser(row, v, rule?.cap) && rule?.capLine && v !== yours ? ` — ${rule.capLine}` : "";
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
          {all.map((v) => (
            <option key={String(v)} value={String(v)} disabled={isLooser(row, v, rule?.cap)}>{words(v)}{reason(v)}</option>
          ))}
        </select>
      );
    }
    case "money":
    case "tokens": {
      const money = row.kind.kind === "money";
      const shown = yours === undefined ? "" : money ? String((yours as { amount: number }).amount) : String(yours);
      return (
        <input id={id} type="text" inputMode="decimal" placeholder={folder ? unset : "No limit"} disabled={!editable} value={shown}
          onChange={(e) => {
            const v = money ? moneyValue(e.currentTarget.value) : tokensValue(e.currentTarget.value);
            if (v !== null) set(v);
          }} />
      );
    }
    case "toggle":
      // A folder's switch can also be left to yours, so it is a menu, as the window's.
      if (folder) {
        return (
          <select id={id} disabled={!editable} value={yours === undefined ? "" : String(yours)}
            onChange={(e) => { const raw = e.currentTarget.value; set(raw === "" ? undefined : raw === "true"); }}>
            <option value="">{unset}</option>
            {[true, false].map((v) => (
              <option key={String(v)} value={String(v)} disabled={isLooser(row, v, rule?.cap)}>{v ? "On" : "Off"}{reason(v)}</option>
            ))}
          </select>
        );
      }
      return <input id={id} type="checkbox" role="switch" disabled={!editable} checked={yours !== false}
        onChange={(e) => set(e.currentTarget.checked)} />;
    case "list":
      return <span id={id} class="quiet">{rule?.decides ? rule.words : folder ? unset : row.unset}</span>;
  }
}
