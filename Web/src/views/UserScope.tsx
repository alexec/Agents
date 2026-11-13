// Settings ▸ You ▸ Secrets (#1760, #3632), as the window's (Shared/UI/UserScope): the person's secrets
// and cards, by name only, which go to every machine of theirs.
import { useEffect, useRef } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import { Failure, type UserSecretKind, type UserSecretNames, type UserSecretRow } from "../protocol/generated";
import { Capability } from "../protocol/capabilities.generated";
import { CallFailed } from "../wire/link";
import { openSealedSecret, sealSecret } from "../wire/sealing";
import { describe, methodNotFound } from "../model/errors";
import { about, addCard, addSecret, asksForAgents, type Card, cardConfirm, cardKind, cardKindLabel, type CardPart, cardParts,
  cardProblem, cardRule, cardValue, clipboardSeconds, copiedLine, copiedSeconds, copyRefused, describedAs, didNotOpen,
  isSecretName, leftOn, nameHint, nextVersion, noCopyYet, parseCard, partLabels, revealNeedsNewerPlane, secretsFoot,
  secretsLeft, secretsTitle, shownFor, shownSeconds, spacedNumber, tidyCard, waitingOn } from "../model/userScope";
import { askBeforeUseWords } from "../model/askBeforeUse";
import { hint, machineNames, notBackedUp, onlyMachine, onlyMachineLine, rowLine } from "../model/secretInfo";
import { SecretInfoLine } from "./SecretInfoLine";
import { AskBeforeUseCheck } from "./AskBeforeUse";
import { Modal } from "./Modal";
import { SecretDescriptionField } from "./SecretDescription";
import { ask } from "./MessageKinds";
import { Icon } from "./Icon";

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

/** A value shown (#5115), and when it hides. */
interface Shown { name: string; version: number; value: string; card: Card | null; until: number }
/** What was just copied: the row, and a card's part. */
interface Copied { name: string; part: CardPart | null }

/**
 * Reveal and Copy (#5112, #5115; specs/5112-view-copy-secrets-accounts/wireframes.md, sections 1 to 6), as the window's
 * SecretShowState: the page asks the control plane for its own sealed copy (user/sealedSecret, which writes the audit
 * entry first), opens it with its own key, and shows or copies the value. One value at a time, for 30 s, in memory
 * only; it hides when the tab is hidden, the section closes, or the secret changes.
 */
function useSecretShow(store: Store, rows: UserSecretRow[]) {
  const shown = useSignal<Shown | null>(null);
  const copied = useSignal<Copied | null>(null);
  const fetching = useSignal<string | null>(null);
  const problems = useSignal<Record<string, string>>({});
  const noCopy = useSignal<Set<string>>(new Set());
  const now = useSignal(Date.now());
  const person = useRef<string | null>(null);
  const timers = useRef<{ hide?: number; copied?: number; tick?: number }>({});
  const can = store.planeHas(Capability.user4);

  const hide = () => {
    window.clearTimeout(timers.current.hide);
    window.clearInterval(timers.current.tick);
    shown.value = null;
  };
  useEffect(() => {
    const hidden = () => { if (document.visibilityState === "hidden") hide(); };
    document.addEventListener("visibilitychange", hidden);
    return () => {
      document.removeEventListener("visibilitychange", hidden);
      hide();
      window.clearTimeout(timers.current.copied);
    };
  }, []);
  // A value shown hides when its secret changed or went; a replaced secret is sealed again, to this page too.
  useEffect(() => {
    const s = shown.value;
    if (s && rows.find((r) => r.name === s.name)?.version !== s.version) hide();
    const kept = [...noCopy.value].filter((name) => rows.some((r) => r.name === name));
    if (kept.length !== noCopy.value.size) noCopy.value = new Set(kept);
  }, [rows]);

  const say = (name: string, problem: string | null) => {
    const next = { ...problems.value };
    if (problem) next[name] = problem; else delete next[name];
    problems.value = next;
  };
  const sealedValue = async (row: UserSecretRow, purpose: "reveal" | "copy", part: CardPart | null): Promise<string | null> => {
    const record = await store.link.keyRecord();
    if (!record) {
      say(row.name, noCopyYet);
      return null;
    }
    fetching.value = row.name;
    say(row.name, null);
    try {
      person.current ??= (await store.link.call("user/secretRecipients", {})).user ?? "";
      const sealed = await store.link.call("user/sealedSecret", { name: row.name as never, purpose, ...(part ? { part } : {}) });
      try {
        return await openSealedSecret(record, person.current, sealed);
      } catch {
        say(row.name, didNotOpen);
        return null;
      }
    } catch (error) {
      if (error instanceof CallFailed && error.code === Failure.noClientCopy) noCopy.value = new Set([...noCopy.value, row.name]);
      else say(row.name, error instanceof CallFailed && error.code === methodNotFound ? revealNeedsNewerPlane : sentence(error));
      return null;
    } finally {
      fetching.value = null;
    }
  };

  const toggle = async (row: UserSecretRow) => {
    if (shown.value?.name === row.name) {
      hide();
      return;
    }
    hide();
    const value = await sealedValue(row, "reveal", null);
    if (value === null) return;
    shown.value = { name: row.name, version: row.version ?? 0, value, card: row.kind === cardKind ? parseCard(value) : null,
      until: Date.now() + shownSeconds * 1000 };
    now.value = Date.now();
    timers.current.tick = window.setInterval(() => { now.value = Date.now(); }, 1000);
    timers.current.hide = window.setTimeout(hide, shownSeconds * 1000);
  };

  const copy = async (row: UserSecretRow, part: CardPart | null = null) => {
    const card = row.kind === cardKind;
    const which = part ?? (card ? "number" : null);
    const value = await sealedValue(row, "copy", which);
    if (value === null) return;
    const parsed = card ? parseCard(value) : null;
    if (card && !parsed) {
      say(row.name, didNotOpen);
      return;
    }
    const text = parsed && which ? parsed[which] : value;
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      say(row.name, copyRefused);
      return;
    }
    // A browser lets a page write the clipboard only while its tab is in front, so the clear is only then.
    window.setTimeout(() => {
      if (document.visibilityState === "visible" && document.hasFocus()) void navigator.clipboard.writeText("").catch(() => undefined);
    }, clipboardSeconds * 1000);
    copied.value = { name: row.name, part: shown.value?.name === row.name ? part : null };
    window.clearTimeout(timers.current.copied);
    timers.current.copied = window.setTimeout(() => { copied.value = null; }, copiedSeconds * 1000);
  };

  return { can, shown, copied, fetching, problems, noCopy, now, toggle, copy };
}

type SecretShow = ReturnType<typeof useSecretShow>;

/** The value shown, in a well that a person cannot select: Copy is the only way to copy it, so each copy is audited. */
function ShownValue({ row, shown, show }: { row: UserSecretRow; shown: Shown; show: SecretShow }) {
  if (!shown.card) return <code class="secret-shown" aria-label={`${row.name} value`}>{shown.value}</code>;
  const card = shown.card;
  return (
    <div class="secret-shown" aria-label={`${row.name} parts`}>
      {cardParts.map((part) => {
        const done = show.copied.value?.name === row.name && show.copied.value.part === part;
        return (
          <div class="card-part" key={part}>
            <span class="part-label">{partLabels[part]}</span>
            <span class="part-value">{part === "number" ? spacedNumber(card.number) : card[part]}</span>
            <button type="button" aria-label={`Copy ${partLabels[part]} of ${row.name}`} onClick={() => void show.copy(row, part)}>
              {done ? "Copied ✓" : "Copy"}
            </button>
          </div>
        );
      })}
    </div>
  );
}

function SecretItem({ row, replace, remove, down, names, oneMachine, show }: { row: UserSecretRow; replace: () => void;
  remove: () => void; down: boolean; names: Record<string, string>; oneMachine: boolean; show: SecretShow }) {
  const left = leftOn(row);
  const waiting = waitingOn(row);
  const warning = oneMachine ? null : notBackedUp(row, names);
  const shown = show.shown.value?.name === row.name ? show.shown.value : null;
  const copied = show.copied.value?.name === row.name ? show.copied.value : null;
  const off = down || show.noCopy.value.has(row.name) || show.fetching.value === row.name;
  const problem = show.problems.value[row.name];
  return (
    <li class="user-secret">
      <code>{row.name}</code>
      {row.kind === cardKind && <span class="hint">{cardKindLabel}</span>}
      {!shown && <code class="hint secret-hint" aria-label={row.hint ? `Ends in ${row.hint}` : "Value hidden"}>{hint(row.hint)}</code>}
      {shown && <ShownValue row={row} shown={shown} show={show} />}
      <p class="hint">{about(row.description)}</p>
      <SecretInfoLine parts={rowLine(row)} />
      {shown && <p class="hint">{shownFor(Math.ceil((shown.until - show.now.value) / 1000), shown.card !== null)}</p>}
      {copied && <p class="hint vouched" role="status"><span aria-hidden="true">✓ </span>{copiedLine(copied.part)}</p>}
      {row.needsApproval && <span class="hint"><Icon name="hand" />{" "}{show.can ? asksForAgents : askBeforeUseWords.asks}</span>}
      {show.noCopy.value.has(row.name) && <p class="hint attention">{noCopyYet}</p>}
      {problem && <p class="failure" role="alert">{problem}</p>}
      {waiting && <p class="hint attention">{waiting}</p>}
      {left && <p class="hint attention">{left}</p>}
      {warning && <p class="hint warning"><Icon name="triangle-alert" />{" "}{warning}</p>}
      <span class="row-actions">
        {show.can && (
          <>
            <button type="button" disabled={off} aria-label={`${shown ? "Hide" : "Reveal"} ${row.name}`} onClick={() => void show.toggle(row)}>
              {show.fetching.value === row.name ? "…" : shown ? "Hide" : "Reveal"}
            </button>
            <button type="button" disabled={off} aria-label={`Copy ${row.name}`} onClick={() => void show.copy(row)}>
              {copied && copied.part === null ? "Copied ✓" : "Copy"}
            </button>
          </>
        )}
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
    if (!await ask(`Remove ${name}? It is taken out of the sealed store on every machine of yours.`)) return;
    try {
      await store.link.call("user/removeSecret", { name });
    } catch (error) {
      store.say(sentence(error));
    }
    await load();
  };
  const left = store.secretsLeft.value;
  const rows = names.value?.secrets ?? [];
  const show = useSecretShow(store, rows);
  const hostNames = machineNames(store.hosts.value);
  const only = onlyMachine(rows);
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
      {only && <p class="hint attention"><Icon name="triangle-alert" />{" "}{onlyMachineLine(only, hostNames)}</p>}
      <ul class="user-secrets">
        {rows.map((row) => (
          <SecretItem key={row.name} row={row} down={down} names={hostNames} oneMachine={only !== null} show={show}
            replace={() => { replacing.value = row; }} remove={() => void remove(row.name)} />
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
