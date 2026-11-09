// Settings ▸ You ▸ Secrets (#1760, #3632), as the window's (Shared/UI/UserScope): the person's secrets
// and cards, by name only, which go to every machine of theirs.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { UserSecretKind, UserSecretNames, UserSecretRow } from "../protocol/generated";
import { CallFailed } from "../wire/link";
import { sealSecret } from "../wire/sealing";
import { describe, methodNotFound } from "../model/errors";
import { about, addCard, addSecret, cardConfirm, cardKind, cardKindLabel, cardProblem, cardRule, cardValue, describedAs,
  isSecretName, leftOn, machines, nameHint, nextVersion, secretsFoot, secretsLeft, secretsTitle, tidyCard, waitingOn } from "../model/userScope";
import { askBeforeUseWords } from "../model/askBeforeUse";
import { AskBeforeUseCheck } from "./AskBeforeUse";
import { Modal } from "./Modal";
import { SecretDescriptionField } from "./SecretDescription";

function sentence(error: unknown): string {
  if (error instanceof CallFailed && error.code === methodNotFound) return "This control plane does not keep settings for you yet. Update it.";
  return describe(error);
}

/** Seals the value here to each of the person's machines and apps (#3397), and sends only the envelopes: the
 * control plane never has it. kind is "card" for a card (#3531). Ask before use (#4016) is sealed into every
 * copy's associated data, so it is set here, on Add and Replace: no client can read a value back to seal it again. */
async function setSecret(store: Store, name: string, value: string, replacing: UserSecretRow | null, ask: boolean,
  description: string, kind?: UserSecretKind) {
  const version = nextVersion(replacing, Date.now());
  const { recipients, user } = await store.link.call("user/secretRecipients", {});
  // Only to the machines the lock names (#3491, D8): the control plane cannot add a key of its own.
  const values = await sealSecret(user ?? "", name, version, value, await store.signedRecipients(recipients), ask);
  await store.link.call("user/setSecret", { name: name as never, version, values, ...(kind ? { kind } : {}),
    ...(ask ? { needsApproval: true } : {}), ...describedAs(description) });
}

function SecretSheet({ store, replacing, close }: { store: Store; replacing: UserSecretRow | null; close: () => void }) {
  const name = useSignal(replacing?.name ?? "");
  const value = useSignal("");
  // A new secret starts on (#4162); a replaced one keeps its own.
  const ask = useSignal(replacing ? replacing.needsApproval === true : true);
  const description = useSignal(replacing?.description ?? "");
  const problem = useSignal<string | null>(null);
  const busy = useSignal(false);
  const save = async () => {
    busy.value = true;
    try {
      await setSecret(store, name.value.trim(), value.value, replacing, ask.value, description.value);
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
    <Modal label={replacing ? `Replace ${replacing.name}` : "Add a Secret"} close={close}>
      <form method="dialog" class="sheet-body" onSubmit={(e) => { e.preventDefault(); void save(); }}>
        <h2>{replacing ? `Replace ${replacing.name}` : "Add a Secret"}</h2>
        {!replacing && (
          <input type="text" aria-label="Name" placeholder="GITHUB_TOKEN" autofocus autocomplete="off" spellcheck={false}
            value={name.value} onInput={(e) => (name.value = (e.currentTarget as HTMLInputElement).value.toUpperCase())} />
        )}
        <input type="password" aria-label="Value" placeholder="Value" autocomplete="off" value={value.value}
          onInput={(e) => (value.value = (e.currentTarget as HTMLInputElement).value)} />
        <SecretDescriptionField text={description} />
        <AskBeforeUseCheck on={ask} />
        <p class={problem.value ? "sheet-note failure" : "sheet-note"} role={problem.value ? "alert" : undefined}>{problem.value ?? nameHint}</p>
        <div class="sheet-actions">
          <button type="button" onClick={close}>Cancel</button>
          <button type="submit" class="prominent" disabled={busy.value || !value.value || !isSecretName(chosen)}>{replacing ? "Replace" : "Add"}</button>
        </div>
      </form>
    </Modal>
  );
}

/** Add a Card… and a card's Replace… (#3531): only a card with a spend limit (a merchant or category lock is recommended). */
function CardSheet({ store, replacing, close }: { store: Store; replacing: UserSecretRow | null; close: () => void }) {
  const name = useSignal(replacing?.name ?? "");
  const number = useSignal("");
  const expiry = useSignal("");
  const cvc = useSignal("");
  const holder = useSignal("");
  const zip = useSignal("");
  const locked = useSignal(false);
  // A new card starts on (#4162); a replaced one keeps its own.
  const ask = useSignal(replacing ? replacing.needsApproval === true : true);
  const description = useSignal(replacing?.description ?? "");
  const problem = useSignal<string | null>(null);
  const busy = useSignal(false);
  const save = async () => {
    const card = tidyCard({ number: number.value, expiry: expiry.value, cvc: cvc.value, name: holder.value, zip: zip.value });
    const wrong = cardProblem(card);
    if (wrong) {
      problem.value = wrong;
      return;
    }
    busy.value = true;
    try {
      await setSecret(store, name.value.trim(), cardValue(card), replacing, ask.value, description.value, cardKind);
      number.value = "";
      cvc.value = "";
      close();
    } catch (error) {
      problem.value = sentence(error);
    } finally {
      busy.value = false;
    }
  };
  const field = (label: string, signal: { value: string }, props: Record<string, unknown> = {}) => (
    <input type="text" aria-label={label} placeholder={label} autocomplete="off" spellcheck={false} value={signal.value}
      onInput={(e) => (signal.value = (e.currentTarget as HTMLInputElement).value)} {...props} />
  );
  const title = replacing ? `Replace ${replacing.name}` : "Add a Card";
  return (
    <Modal label={title} close={close}>
      <form method="dialog" class="sheet-body" onSubmit={(e) => { e.preventDefault(); void save(); }}>
        <h2>{title}</h2>
        <p class="sheet-note">{cardRule}</p>
        <label>
          <input type="checkbox" checked={locked.value} onChange={(e) => (locked.value = (e.currentTarget as HTMLInputElement).checked)} />
          {" "}{cardConfirm}
        </label>
        {!replacing && (
          <input type="text" aria-label="Name" placeholder="SHOP_CARD" autocomplete="off" spellcheck={false}
            value={name.value} onInput={(e) => (name.value = (e.currentTarget as HTMLInputElement).value.toUpperCase())} />
        )}
        {field("Card number", number, { type: "password", inputMode: "numeric" })}
        {field("Expiry (MM/YY)", expiry, { inputMode: "numeric" })}
        {field("CVC", cvc, { type: "password", inputMode: "numeric" })}
        {field("Name on card", holder)}
        {field("Billing ZIP", zip)}
        <SecretDescriptionField text={description} />
        <AskBeforeUseCheck on={ask} />
        <p class={problem.value ? "sheet-note failure" : "sheet-note"} role={problem.value ? "alert" : undefined}>{problem.value ?? nameHint}</p>
        <div class="sheet-actions">
          <button type="button" onClick={close}>Cancel</button>
          <button type="submit" class="prominent"
            disabled={busy.value || !locked.value || !number.value || !cvc.value || !isSecretName(name.value.trim())}>
            {replacing ? "Replace" : "Add"}
          </button>
        </div>
      </form>
    </Modal>
  );
}

function SecretItem({ row, replace, remove, down }: { row: UserSecretRow; replace: () => void; remove: () => void; down: boolean }) {
  const left = leftOn(row);
  const waiting = waitingOn(row);
  return (
    <li class="user-secret">
      <code>{row.name}</code>
      {row.kind === cardKind && <span class="hint">{cardKindLabel}</span>}
      <p class="hint">{about(row.description)}</p>
      <span class="hint">{machines(row)}</span>
      {row.needsApproval && <span class="hint"><span aria-hidden="true">✋ </span>{askBeforeUseWords.asks}</span>}
      {waiting && <p class="hint attention">{waiting}</p>}
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
  const addingCard = useSignal(false);
  const replacing = useSignal<UserSecretRow | null>(null);
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
          <SecretItem key={row.name} row={row} down={down} replace={() => { replacing.value = row; }} remove={() => void remove(row.name)} />
        ))}
      </ul>
      <button type="button" disabled={down} onClick={() => { adding.value = true; }}>{addSecret}</button>
      <button type="button" disabled={down} onClick={() => { addingCard.value = true; }}>{addCard}</button>
      <p class="hint">{secretsFoot}</p>
      {adding.value && <SecretSheet store={store} replacing={null} close={() => { adding.value = false; void load(); }} />}
      {addingCard.value && <CardSheet store={store} replacing={null} close={() => { addingCard.value = false; void load(); }} />}
      {replacing.value && (replacing.value.kind === cardKind
        ? <CardSheet store={store} replacing={replacing.value} close={() => { replacing.value = null; void load(); }} />
        : <SecretSheet store={store} replacing={replacing.value} close={() => { replacing.value = null; void load(); }} />)}
    </section>
  );
}
