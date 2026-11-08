// Settings ▸ You ▸ Accounts (#3967), as the window's (App/Sources/Accounts): the person's outside accounts, the
// accounts part of their settings, which go to every machine of theirs as their secrets do. A record holds no
// secret, only the name of one in Settings ▸ You ▸ Secrets.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { JSONValue, OutsideAccount, OutsideAccounts } from "../protocol/generated";
import { CallFailed } from "../wire/link";
import { describe, methodNotFound } from "../model/errors";
import { type AccountFields, accountCost, accountDetail, accountFields, accountOf, accountProjects, accountsFoot, accountsOf,
  accountsTitle, expiresSoon, noSecrets, sameAccount } from "../model/accounts";
import { Modal } from "./Modal";

function sentence(error: unknown): string {
  if (error instanceof CallFailed && error.code === methodNotFound) return "This control plane does not keep settings for you yet. Update it.";
  return describe(error);
}

const FIELDS: [key: string, label: string, hint: string][] = [
  ["service", "Service", "gitlab.com"], ["address", "Address", "name@example.com"], ["plan", "Plan", "Free"],
  ["cost", "Monthly cost (USD)", "0"], ["card", "Card", "The card's name in Secrets"], ["secret", "Secret", "The token's name in Secrets"],
  ["twoFactor", "Two-factor", "TOTP, passkey, SMS"], ["issue", "Issue", "#12"], ["made", "Made", "YYYY-MM-DD"],
  ["tokenExpires", "Token expires", "YYYY-MM-DD"], ["projects", "Projects", "None is all, else names with commas"],
  ["notes", "Notes", "Where the password is"],
];

/** Add Account… and Edit…: the record's fields, each optional but the service. */
function AccountSheet({ editing, save, close }: { editing: OutsideAccount | null; save: (a: OutsideAccount) => Promise<string | null>; close: () => void }) {
  const fields = useSignal<AccountFields>(editing ? accountFields(editing) : {});
  const problem = useSignal<string | null>(null);
  const busy = useSignal(false);
  const title = editing ? `Edit ${editing.service}` : "Add an Account";
  const submit = async () => {
    busy.value = true;
    problem.value = await save(accountOf(fields.value));
    busy.value = false;
    if (!problem.value) close();
  };
  return (
    <Modal label={title} close={close}>
      <form method="dialog" class="sheet-body" onSubmit={(e) => { e.preventDefault(); void submit(); }}>
        <h2>{title}</h2>
        {FIELDS.map(([key, label, hint], i) => (
          <input key={key} type="text" aria-label={label} placeholder={`${label}: ${hint}`} autocomplete="off" spellcheck={false}
            autofocus={i === 0} value={fields.value[key] ?? ""}
            onInput={(e) => (fields.value = { ...fields.value, [key]: (e.currentTarget as HTMLInputElement).value })} />
        ))}
        <p class={problem.value ? "sheet-note failure" : "sheet-note"} role={problem.value ? "alert" : undefined}>{problem.value ?? noSecrets}</p>
        <div class="sheet-actions">
          <button type="button" onClick={close}>Cancel</button>
          <button type="submit" class="prominent" disabled={busy.value || !(fields.value.service ?? "").trim()}>{editing ? "Save" : "Add"}</button>
        </div>
      </form>
    </Modal>
  );
}

export function AccountsSection({ store, down }: { store: Store; down: boolean }) {
  const all = useSignal<OutsideAccount[]>([]);
  const problem = useSignal<string | null>(null);
  const project = useSignal("");
  const adding = useSignal(false);
  const editing = useSignal<OutsideAccount | null>(null);
  const load = async () => {
    try {
      const settings = await store.link.call("user/settings", {});
      all.value = (settings.accounts as OutsideAccounts | undefined)?.accounts ?? [];
      problem.value = null;
    } catch (error) {
      problem.value = sentence(error);
    }
  };
  const changes = store.userScopeChanges.value;
  useEffect(() => { if (!down) void load(); }, [changes, down]);
  /** The accounts with replacing taken out and adding put in its place, set as the part. */
  const save = async (adding: OutsideAccount | null, replacing: OutsideAccount | null): Promise<string | null> => {
    const accounts = [...all.value];
    const at = replacing ? accounts.findIndex((a) => sameAccount(a, replacing)) : -1;
    if (at >= 0) accounts.splice(at, 1);
    if (adding) accounts.splice(at >= 0 ? at : accounts.length, 0, adding);
    try {
      const value: OutsideAccounts = { accounts };
      await store.link.call("user/setSettings", { part: "accounts", value: value as unknown as JSONValue });
      await load();
      return null;
    } catch (error) {
      return sentence(error);
    }
  };
  const remove = async (a: OutsideAccount) => {
    if (!window.confirm(`Remove ${a.service}? Only the record goes. The account itself, and its secrets, stay.`)) return;
    const failed = await save(null, a);
    if (failed) store.say(failed);
  };
  const projects = accountProjects(all.value);
  const shown = accountsOf(all.value, project.value);
  const now = Date.now();
  return (
    <section aria-labelledby="settings-accounts">
      <h3 class="section-head" id="settings-accounts">{accountsTitle}</h3>
      {problem.value && <p class="hint">{problem.value}</p>}
      {projects.length > 0 && (
        <label>
          Project{" "}
          <select value={project.value} onChange={(e) => (project.value = (e.currentTarget as HTMLSelectElement).value)}>
            <option value="">All</option>
            {projects.map((p) => <option key={p} value={p}>{p}</option>)}
          </select>
        </label>
      )}
      <ul class="user-secrets">
        {shown.map((a) => {
          const soon = expiresSoon(a, now);
          return (
            <li class="user-secret" key={`${a.service}#${a.address ?? ""}`}>
              <span>{a.service}</span>
              <span class="hint">{accountDetail(a)}</span>
              <span class="hint">{accountCost(a)}</span>
              {soon && <p class="hint attention">{soon}</p>}
              <span class="row-actions">
                <button type="button" disabled={down} onClick={() => { editing.value = a; }}>Edit…</button>
                <button type="button" class="destructive" disabled={down} onClick={() => void remove(a)}>Remove…</button>
              </span>
            </li>
          );
        })}
      </ul>
      <button type="button" disabled={down} onClick={() => { adding.value = true; }}>Add Account…</button>
      <p class="hint">{accountsFoot(shown)}</p>
      {adding.value && <AccountSheet editing={null} save={(a) => save(a, null)} close={() => { adding.value = false; }} />}
      {editing.value && <AccountSheet editing={editing.value} save={(a) => save(a, editing.value)} close={() => { editing.value = null; }} />}
    </section>
  );
}
