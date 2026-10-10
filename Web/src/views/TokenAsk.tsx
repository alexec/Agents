// A server's key ask (043, #344), the window's TokenAskCard: asked before a server agent starts,
// rather than starting one that will fail. The page keeps no key; one pasted here is lent on this
// browser's connection to that server, and the start goes ahead.
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import { keyWords } from "../model/credentials";
import { hostLabel } from "./NewProject";
import { Modal } from "./Modal";

export function TokenAskDialog({ store }: { store: Store }) {
  const ask = store.tokenAsk.value;
  if (!ask) return null;
  return <TokenAskCard key={`${ask.host}|${ask.runtimeID}`} store={store} host={ask.host} runtimeID={ask.runtimeID} />;
}

function TokenAskCard({ store, host, runtimeID }: { store: Store; host: string; runtimeID: string }) {
  const text = useSignal("");
  const problem = useSignal<string | null>(null);
  const saving = useSignal(false);
  const name = (store.runtimes.value[host] ?? []).find((r) => r.runtime.id === runtimeID)?.runtime.name ?? runtimeID;
  const label = hostLabel(store, host);
  const cancel = () => store.finishTokenAsk(false);
  const lend = async () => {
    saving.value = true;
    const why = await store.lendKey(text.value);
    saving.value = false;
    problem.value = why === "notAKey" ? keyWords.notAKey : why;
  };
  return (
    <Modal label={keyWords.title(name, label)} close={cancel}>
      <form method="dialog" class="sheet-body" onSubmit={(e) => { e.preventDefault(); void lend(); }}>
        <h2>{keyWords.title(name, label)}</h2>
        <p class="sheet-note">{keyWords.body(name, label)}</p>
        <input type="password" aria-label={keyWords.field(name)} placeholder={keyWords.field(name)} autofocus
          autocomplete="off" spellcheck={false} value={text.value}
          onInput={(e) => (text.value = (e.currentTarget as HTMLInputElement).value)} />
        {problem.value && <p class="sheet-note failure" role="alert">{problem.value}</p>}
        <p class="sheet-note">{keyWords.source}</p>
        <div class="sheet-actions">
          <button type="button" onClick={cancel}>Cancel</button>
          <button type="submit" class="prominent" disabled={!text.value || saving.value}>{keyWords.action}</button>
        </div>
      </form>
    </Modal>
  );
}
