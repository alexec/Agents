// Console ▸ Model Access (#999, spec 999 FR-027): the organisation's ways to the model. Each route (an org key,
// or a gateway: Bedrock, Vertex, Azure, a base URL), who may use it, the runtimes it is the default for, the
// fingerprint of each key and how many machines hold it; Add Route, Edit, Check, Replace Key and Remove. A key is
// written and never read back, also by an admin (spec D14).
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { Group, OrgRouteKept, OrgRouteKind, OrgRouteList, OrgRouteVendor } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { failedWords } from "../model/console";
import { actorName, runtimeName, when } from "../model/orgPolicy";
import { fingerprintWords, heldWords, kindName, kinds, modelAccessFoot, needsVendor, newRouteForm, noSealing, routeFormOf, routeOf,
  runtimesFor, secretFields, settingFields, vendorNames, vendorsFor, whoWords } from "../model/orgAccounts";
import type { RouteForm } from "../model/orgAccounts";

/** What the page is doing: the list, adding or editing a route, or replacing one's key. */
type Open = { kind: "list" } | { kind: "edit"; kept: OrgRouteKept | null; form: RouteForm } | { kind: "replace"; kept: OrgRouteKept; secrets: Record<string, string> };

export function ModelAccessPage({ store, down }: { store: Store; down: boolean }) {
  const list = useSignal<OrgRouteList | null>(null);
  const groups = useSignal<Group[]>([]);
  const problem = useSignal<string | null>(null);
  const said = useSignal<string | null>(null);
  const busy = useSignal(false);
  const open = useSignal<Open>({ kind: "list" });
  const load = async () => {
    try {
      const [l, g] = await Promise.all([store.link.call("orgRoutes/list", {}), store.link.call("groups/list", {}).catch(() => ({ groups: [] }))]);
      list.value = l;
      groups.value = g.groups;
      problem.value = null;
    } catch (error) {
      problem.value = failedWords(error);
    }
  };
  // Again when another admin changes a route, or a machine says what it holds.
  const changes = store.orgRoutesChanges.value;
  useEffect(() => { if (!down) void load(); }, [down, changes]);
  const groupName = (id: string) => groups.value.find((g) => g.id === id)?.name;
  const run = async (work: () => Promise<string | null>) => {
    busy.value = true;
    try {
      said.value = await work();
      problem.value = null;
    } catch (error) {
      problem.value = failedWords(error);
    } finally {
      busy.value = false;
    }
  };
  const save = (form: RouteForm, kept: OrgRouteKept | null) => run(async () => {
    const made = routeOf(form, kept?.route);
    if ("problem" in made) { problem.value = made.problem; return null; }
    const params = { route: made.route, ...(Object.keys(made.secrets).length > 0 && { secrets: made.secrets }), ...(kept && { rev: kept.rev }) };
    const result = await store.link.call("orgRoutes/set", params);
    open.value = { kind: "list" };
    await load();
    return `Saved ${result.route.name}. Each machine that may use it has it within seconds.`;
  });
  const replace = (kept: OrgRouteKept, secrets: Record<string, string>) => run(async () => {
    const typed = Object.fromEntries(Object.entries(secrets).map(([k, v]) => [k, v.trim()]).filter(([, v]) => v !== ""));
    if (Object.keys(typed).length === 0) { problem.value = "Type the new key."; return null; }
    await store.link.call("orgRoutes/replaceKey", { id: kept.route.id, secrets: typed, rev: kept.rev });
    open.value = { kind: "list" };
    await load();
    return `Replaced the key of ${kept.route.name}.`;
  });
  const check = (kept: OrgRouteKept) => run(async () => {
    const result = await store.link.call("orgRoutes/check", { id: kept.route.id });
    return `${kept.route.name}: ${result.words}`;
  });
  const remove = (kept: OrgRouteKept) => {
    if (!window.confirm(`Remove ${kept.route.name}?\n\nEach machine deletes its key, and the sessions on it stop at their next turn. Members fall back to their own sign-in where the policy allows it.`)) return;
    void run(async () => {
      await store.link.call("orgRoutes/remove", { id: kept.route.id, rev: kept.rev });
      await load();
      return `Removed ${kept.route.name}.`;
    });
  };
  const shown = list.value;
  if (!shown) return problem.value ? <p class="hint" role="alert">{problem.value}</p> : <p class="hint">Loading…</p>;
  const now = open.value;
  return (
    <div class="model-access">
      {problem.value && <p class="hint" role="alert">{problem.value}</p>}
      {said.value && <p class="quiet small" role="status">{said.value}</p>}
      {!shown.sealing && <p class="hint attention">{noSealing}</p>}
      {now.kind === "edit" && (
        <RouteEditor form={now.form} kept={now.kept} groups={groups.value} busy={busy.value || down}
          change={(form) => { open.value = { ...now, form }; }} save={() => void save(now.form, now.kept)}
          cancel={() => { open.value = { kind: "list" }; problem.value = null; }} />
      )}
      {now.kind === "replace" && (
        <form class="org-policy" onSubmit={(e) => { e.preventDefault(); void replace(now.kept, now.secrets); }}>
          <h3 class="section-head">Replace the Key of {now.kept.route.name}</h3>
          {secretFields[now.kept.route.kind].map((f) => (
            <SecretField key={f.key} label={f.label} long={f.long} value={now.secrets[f.key] ?? ""}
              change={(v) => { open.value = { ...now, secrets: { ...now.secrets, [f.key]: v } }; }} />
          ))}
          <p class="hint">The old key is not shown, and stops being used as each machine gets the new one.</p>
          <div class="sheet-actions">
            <button type="button" disabled={busy.value} onClick={() => { open.value = { kind: "list" }; }}>Cancel</button>
            <button type="submit" class="prominent" disabled={busy.value || down}>Replace Key</button>
          </div>
        </form>
      )}
      {now.kind === "list" && (
        <>
          {shown.routes.length === 0 ? <p class="hint">No routes yet. Each runtime uses each person’s own sign-in.</p> : (
            <table class="console-table">
              <thead>
                <tr><th>Route</th><th>For</th><th>Who</th><th>Key</th><th class="num">Machines</th><th /></tr>
              </thead>
              <tbody>
                {shown.routes.map((kept) => {
                  const r = kept.route;
                  return (
                    <tr key={r.id}>
                      <td>
                        <span class="strong">{r.name}</span><br />
                        <span class="quiet small">{kindName(r.kind)}{r.vendor ? ` · ${vendorNames[r.vendor]}` : ""}{r.version ? ` · v${r.version}` : ""}</span>
                      </td>
                      <td>
                        {r.runtimes.map(runtimeName).join(", ")}
                        {(r.defaultFor?.length ?? 0) > 0 && <><br /><span class="quiet small">Default for {r.defaultFor!.map(runtimeName).join(", ")}</span></>}
                      </td>
                      <td>{whoWords(r, groupName)}</td>
                      <td>
                        <span class="small">{fingerprintWords(r)}</span>
                        {r.changed && <><br /><span class="quiet small">By {actorName(r.changed.by)} {when(fromWireDate(r.changed.at), new Date())}</span></>}
                      </td>
                      <td class="num" title={heldWords(r)}>{r.machines ?? 0}</td>
                      <td class="route-actions">
                        <button type="button" class="link" disabled={busy.value || down} onClick={() => void check(kept)}>Check</button>
                        <button type="button" class="link" disabled={busy.value || down} onClick={() => { said.value = null; open.value = { kind: "edit", kept, form: routeFormOf(r) }; }}>Edit…</button>
                        <button type="button" class="link" disabled={busy.value || down || (r.secretFields?.length ?? 0) === 0}
                          onClick={() => { said.value = null; open.value = { kind: "replace", kept, secrets: {} }; }}>Replace Key…</button>
                        <button type="button" class="link destructive" disabled={busy.value || down} onClick={() => remove(kept)}>Remove…</button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          )}
          <div class="sheet-actions">
            <button type="button" class="prominent" disabled={down} onClick={() => { said.value = null; open.value = { kind: "edit", kept: null, form: newRouteForm() }; }}>Add Route…</button>
          </div>
        </>
      )}
      <p class="hint">{modelAccessFoot}</p>
    </div>
  );
}

function SecretField({ label, long, value, change }: { label: string; long?: boolean | undefined; value: string; change: (value: string) => void }) {
  return (
    <label class="setting">
      <span>{label}</span>
      {long
        ? <textarea rows={3} autocomplete="off" spellcheck={false} placeholder="Not shown again" aria-label={label} value={value}
            onInput={(e) => change((e.currentTarget as HTMLTextAreaElement).value)} />
        : <input type="password" autocomplete="new-password" placeholder="Not shown again" aria-label={label} value={value}
            onInput={(e) => change((e.currentTarget as HTMLInputElement).value)} />}
    </label>
  );
}

function RouteEditor({ form, kept, groups, busy, change, save, cancel }: { form: RouteForm; kept: OrgRouteKept | null; groups: Group[];
  busy: boolean; change: (form: RouteForm) => void; save: () => void; cancel: () => void }) {
  const set = (next: Partial<RouteForm>) => change({ ...form, ...next });
  const vendor = needsVendor(form.kind) && form.vendor !== "" ? form.vendor : undefined;
  const can = runtimesFor(form.kind, vendor);
  const toggle = (list: string[], id: string, on: boolean) => on ? [...list.filter((x) => x !== id), id] : list.filter((x) => x !== id);
  const has = kept?.route.secretFields ?? [];
  return (
    <form class="org-policy" onSubmit={(e) => { e.preventDefault(); save(); }}>
      <h3 class="section-head">{kept ? `Edit ${kept.route.name}` : "Add Route"}</h3>
      <label class="setting">
        <span>Name members see</span>
        <input type="text" placeholder="Acme Bedrock" aria-label="Name" value={form.name} onInput={(e) => set({ name: (e.currentTarget as HTMLInputElement).value })} />
      </label>
      <label class="setting">
        <span>Kind</span>
        <select aria-label="Kind" value={form.kind} disabled={kept !== null} onChange={(e) => {
          const kind = (e.currentTarget as HTMLSelectElement).value as OrgRouteKind;
          const vendors = vendorsFor(kind);
          set({ kind, vendor: vendors.includes(form.vendor as OrgRouteVendor) ? form.vendor : vendors[0] ?? "", secrets: {} });
        }}>
          {kinds.map((k) => <option key={k} value={k}>{kindName(k)}</option>)}
        </select>
      </label>
      {needsVendor(form.kind) && (
        <label class="setting">
          <span>Speaks the API of</span>
          <select aria-label="API" value={form.vendor} onChange={(e) => set({ vendor: (e.currentTarget as HTMLSelectElement).value as OrgRouteVendor })}>
            {vendorsFor(form.kind).map((v) => <option key={v} value={v}>{vendorNames[v]}</option>)}
          </select>
        </label>
      )}
      <fieldset class="group-people">
        <legend>For these runtimes</legend>
        {can.map((id) => (
          <div key={id} class="setting">
            <label><input type="checkbox" checked={form.runtimes.includes(id)}
              onChange={(e) => set({ runtimes: toggle(form.runtimes, id, (e.currentTarget as HTMLInputElement).checked) })} /> {runtimeName(id)}</label>
            <label class="small"><input type="checkbox" aria-label={`Default for ${runtimeName(id)}`} disabled={!form.runtimes.includes(id)}
              checked={form.defaultFor.includes(id)}
              onChange={(e) => set({ defaultFor: toggle(form.defaultFor, id, (e.currentTarget as HTMLInputElement).checked) })} /> Default</label>
          </div>
        ))}
      </fieldset>
      <p class="hint">Cursor, Copilot, Antigravity and Grok cannot use a route: their model traffic cannot go through the machine’s relay. Default makes it the account each member’s new sessions use, unless they choose another.</p>
      {settingFields[form.kind].map((f) => (
        <label key={f.key} class="setting">
          <span>{f.label}</span>
          <input type="text" placeholder={f.placeholder} aria-label={f.label} value={form.settings[f.key] ?? ""}
            onInput={(e) => set({ settings: { ...form.settings, [f.key]: (e.currentTarget as HTMLInputElement).value } })} />
        </label>
      ))}
      {secretFields[form.kind].map((f) => (
        <SecretField key={f.key} label={has.includes(f.key) ? `${f.label} (set; empty keeps it)` : f.label} long={f.long}
          value={form.secrets[f.key] ?? ""} change={(v) => set({ secrets: { ...form.secrets, [f.key]: v } })} />
      ))}
      <label class="setting">
        <span>Model map</span>
        <textarea rows={2} spellcheck={false} placeholder="claude-sonnet-4-5 = us.anthropic.claude-sonnet-4-5-v1:0" aria-label="Model map"
          value={form.models} onInput={(e) => set({ models: (e.currentTarget as HTMLTextAreaElement).value })} />
      </label>
      <p class="hint">One a line: the runtime’s model id, then the gateway’s. Empty: the runtime’s ids as they are.</p>
      <fieldset class="group-people">
        <legend>Who may use it</legend>
        {groups.length === 0 && <p class="hint">Everyone. Make groups in People and Groups to give it to some people only.</p>}
        {groups.map((g) => (
          <label key={g.id} class="setting">
            <span>{g.name}</span>
            <input type="checkbox" checked={form.groups.includes(g.id)} onChange={(e) => set({ groups: toggle(form.groups, g.id, (e.currentTarget as HTMLInputElement).checked) })} />
          </label>
        ))}
        {groups.length > 0 && <p class="hint">{form.groups.length === 0 ? "No group chosen: everyone." : "Only the people in the groups chosen."}</p>}
      </fieldset>
      <div class="sheet-actions">
        <button type="button" disabled={busy} onClick={cancel}>Cancel</button>
        <button type="submit" class="prominent" disabled={busy}>{kept ? "Save" : "Add Route"}</button>
      </div>
    </form>
  );
}
