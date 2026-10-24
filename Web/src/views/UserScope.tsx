// Machines ▸ Secrets and the parts at the end of Machines (#1760, #2157), as the window's and the
// Remote's (Shared/UI/UserScope): the person's secrets, by name only, and which settings are the
// same on every machine of theirs. Turning one on is the Mac's, at the top of its pane: the
// settings are a machine's files.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { UserSecretNames, UserSecretRow } from "../protocol/generated";
import { CallFailed } from "../wire/link";
import { describe, methodNotFound } from "../model/errors";
import { addSecret, isSecretName, leftOn, machines, nameHint, noSealing,
  secretsFoot, secretsLeft, secretsTitle } from "../model/userScope";
import { Modal } from "./Modal";

function sentence(error: unknown): string {
  if (error instanceof CallFailed && error.code === methodNotFound) return "This control plane does not keep settings for you yet. Update it.";
  return describe(error);
}

function SecretSheet({ store, replacing, close }: { store: Store; replacing: string | null; close: () => void }) {
  const name = useSignal(replacing ?? "");
  const value = useSignal("");
  const problem = useSignal<string | null>(null);
  const busy = useSignal(false);
  const save = async () => {
    busy.value = true;
    try {
      await store.link.call("user/setSecret", { name: name.value.trim(), value: value.value });
      value.value = "";
      close();
    } catch (error) {
      problem.value = sentence(error);
    } finally {
      busy.value = false;
    }
  };
  const chosen = name.value.trim();
  return (
    <Modal label={replacing ? `Replace ${replacing}` : "Add a Secret"} close={close}>
      <form method="dialog" class="sheet-body" onSubmit={(e) => { e.preventDefault(); void save(); }}>
        <h2>{replacing ? `Replace ${replacing}` : "Add a Secret"}</h2>
        {!replacing && (
          <input type="text" aria-label="Name" placeholder="GITHUB_TOKEN" autofocus autocomplete="off" spellcheck={false}
            value={name.value} onInput={(e) => (name.value = (e.currentTarget as HTMLInputElement).value.toUpperCase())} />
        )}
        <input type="password" aria-label="Value" placeholder="Value" autocomplete="off" value={value.value}
          onInput={(e) => (value.value = (e.currentTarget as HTMLInputElement).value)} />
        <p class={problem.value ? "sheet-note failure" : "sheet-note"} role={problem.value ? "alert" : undefined}>{problem.value ?? nameHint}</p>
        <div class="sheet-actions">
          <button type="button" onClick={close}>Cancel</button>
          <button type="submit" class="prominent" disabled={busy.value || !value.value || !isSecretName(chosen)}>{replacing ? "Replace" : "Add"}</button>
        </div>
      </form>
    </Modal>
  );
}

function SecretItem({ row, replace, remove, down }: { row: UserSecretRow; replace: () => void; remove: () => void; down: boolean }) {
  const left = leftOn(row);
  return (
    <li class="user-secret">
      <code>{row.name}</code>
      <span class="hint">{machines(row)}</span>
      {left && <p class="hint attention">{left}</p>}
      <span class="row-actions">
        <button type="button" disabled={down} onClick={replace}>Replace…</button>
        <button type="button" class="destructive" disabled={down} onClick={remove}>Remove…</button>
      </span>
    </li>
  );
}

/** What the control plane keeps for the person, read again on each control/userSettingsChanged and on each
 * connection. */
function useUserScope(store: Store, down: boolean) {
  const names = useSignal<UserSecretNames | null>(null);
  const problem = useSignal<string | null>(null);
  const load = async () => {
    try {
      names.value = await store.link.call("user/secretNames", {});
      problem.value = null;
    } catch (error) {
      problem.value = sentence(error);
    }
  };
  const changes = store.userScopeChanges.value;
  useEffect(() => { if (!down) void load(); }, [changes, down]);
  return { names, problem, load };
}

export function SecretsSection({ store, down }: { store: Store; down: boolean }) {
  const { names, problem, load } = useUserScope(store, down);
  const adding = useSignal(false);
  const replacing = useSignal<string | null>(null);
  const remove = async (name: string) => {
    if (!window.confirm(`Remove ${name}? It is taken out of secrets.env on every machine of yours.`)) return;
    try {
      await store.link.call("user/removeSecret", { name });
    } catch (error) {
      store.say(sentence(error));
    }
    await load();
  };
  const left = store.secretsLeft.value;
  return (
    <section aria-labelledby="settings-secrets">
      <h3 class="section-head" id="settings-secrets">{secretsTitle}</h3>
      {problem.value && <p class="hint">{problem.value}</p>}
      {left && (
        <div class="banner attention" role="status">
          <p>{secretsLeft(left)}</p>
          <button type="button" onClick={() => { store.secretsLeft.value = null; }}>OK</button>
        </div>
      )}
      <ul class="user-secrets">
        {(names.value?.secrets ?? []).map((row) => (
          <SecretItem key={row.name} row={row} down={down} replace={() => { replacing.value = row.name; }} remove={() => void remove(row.name)} />
        ))}
      </ul>
      {names.value && !names.value.sealing
        ? <p class="hint">{noSealing}</p>
        : <button type="button" disabled={down} onClick={() => { adding.value = true; }}>{addSecret}</button>}
      <p class="hint">{secretsFoot}</p>
      {adding.value && <SecretSheet store={store} replacing={null} close={() => { adding.value = false; void load(); }} />}
      {replacing.value && <SecretSheet store={store} replacing={replacing.value} close={() => { replacing.value = null; void load(); }} />}
    </section>
  );
}
