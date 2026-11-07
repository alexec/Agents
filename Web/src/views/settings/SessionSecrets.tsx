// Your setup ▸ Secrets ▸ For One Session (#3548, #3632): a machine's secrets for one session only, each
// with the session it belongs to and a Remove, and Add for a Session…. Listed in ./sections.ts, after the
// person's secrets. As the window's SessionSecretsSection.
import { signal, useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { SessionSecret, SessionSecrets, UUID } from "../../protocol/generated";
import type { Store } from "../../model/store";
import { describe } from "../../model/errors";
import { isSecretName } from "../../model/userScope";
import { removeQuestion, sessionSecretWords, sessionsForSecrets } from "../../model/sessionSecrets";
import { Modal } from "../Modal";
import { useSettingsMachine } from "./SettingsMachine";

const lists = signal<Record<string, SessionSecrets | null>>({});
const adding = signal(false);

export function SessionSecretsSection({ store, down }: { store: Store; down: boolean }) {
  const { host, picker } = useSettingsMachine(store);
  useEffect(() => {
    if (!host) return;
    void store.link.call("secrets/sessionList", {}, host).then(
      (list) => { lists.value = { ...lists.value, [host]: list }; },
      // A host too old to keep them: the section stays out.
      () => { lists.value = { ...lists.value, [host]: null }; },
    );
  }, [store, host]);
  const list = host ? lists.value[host] : undefined;
  if (list === null) return null;
  const remove = async (secret: SessionSecret) => {
    if (!host || !window.confirm(`${removeQuestion(secret)} ${sessionSecretWords.removeMessage}`)) return;
    try {
      const after = await store.link.call("secrets/sessionRemove", { agentID: secret.agentID, name: secret.name }, host);
      lists.value = { ...lists.value, [host]: after };
    } catch (error) {
      store.say(describe(error));
    }
  };
  return (
    <section aria-labelledby="settings-session-secrets">
      <h3 class="section-head" id="settings-session-secrets">{sessionSecretWords.header}</h3>
      {picker}
      {!list ? <p class="hint">Loading…</p> : list.secrets.length === 0 ? <p class="hint">{sessionSecretWords.none}</p> : null}
      {list?.secrets.map((s) => (
        <div class="setting" key={`${s.agentID}/${s.name}`}>
          <span><code>{s.name}</code> <span class="faint small">{s.title}</span></span>
          <button type="button" aria-label={`Remove ${s.name} from ${s.title}`} disabled={down}
            onClick={() => void remove(s)}>Remove…</button>
        </div>
      ))}
      {list && (
        <div class="setting">
          <span />
          <button type="button" disabled={down} onClick={() => (adding.value = true)}>{sessionSecretWords.add}</button>
        </div>
      )}
      <p class="hint">{sessionSecretWords.footer}</p>
      {adding.value && host && (
        <SessionSecretSheet store={store} host={host} close={() => (adding.value = false)}
          saved={(after) => { lists.value = { ...lists.value, [host]: after }; }} />
      )}
    </section>
  );
}

/** Add for a Session…: which session, a name and a value. The value is never shown again. */
function SessionSecretSheet({ store, host, close, saved }: {
  store: Store; host: string; close: () => void; saved: (after: SessionSecrets) => void;
}) {
  const sessions = sessionsForSecrets(store.agents.value[host] ?? []);
  const session = useSignal<UUID | null>(sessions[0]?.id ?? null);
  const name = useSignal("");
  const value = useSignal("");
  const problem = useSignal<string | null>(null);
  const busy = useSignal(false);
  const chosen = name.value.trim();
  const save = async () => {
    if (!session.value) return;
    busy.value = true;
    try {
      saved(await store.link.call("secrets/sessionSet", { agentID: session.value, name: chosen, value: value.value }, host));
      value.value = "";
      close();
    } catch (error) {
      problem.value = describe(error);
    } finally {
      busy.value = false;
    }
  };
  return (
    <Modal label={sessionSecretWords.sheetTitle} close={close}>
      <form method="dialog" class="sheet-body" onSubmit={(e) => { e.preventDefault(); void save(); }}>
        <h2>{sessionSecretWords.sheetTitle}</h2>
        {sessions.length === 0 ? <p class="sheet-note">{sessionSecretWords.noSessions}</p> : (
          <label class="setting">{sessionSecretWords.session}{" "}
            <select value={session.value ?? ""} onChange={(e) => (session.value = e.currentTarget.value as UUID)}>
              {sessions.map((a) => <option key={a.id} value={a.id}>{a.title ?? "Untitled session"}</option>)}
            </select>
          </label>
        )}
        <input type="text" aria-label="Name" placeholder="SHOP_PASSWORD" autofocus autocomplete="off" spellcheck={false}
          value={name.value} onInput={(e) => (name.value = (e.currentTarget as HTMLInputElement).value.toUpperCase())} />
        <input type="password" aria-label="Value" placeholder="Value" autocomplete="off" value={value.value}
          onInput={(e) => (value.value = (e.currentTarget as HTMLInputElement).value)} />
        <p class={problem.value ? "sheet-note failure" : "sheet-note"} role={problem.value ? "alert" : undefined}>
          {problem.value ?? sessionSecretWords.footer}
        </p>
        <div class="sheet-actions">
          <button type="button" onClick={close}>Cancel</button>
          <button type="submit" class="prominent" disabled={busy.value || !session.value || !value.value || !isSecretName(chosen)}>Add</button>
        </div>
      </form>
    </Modal>
  );
}
