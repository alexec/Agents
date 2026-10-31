// Console ▸ Read API (#2019, #1804 decision 4): an admin makes a token for each BI tool that reads
// the organisation's reports at /v1/read/reports, sees each one's last use, and revokes it; and sees
// the OTLP exporter, which agents-control's environment turns on. The web page's only (#1804, decision 1).
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { ReadAPI, ReadTokenMade } from "../protocol/generated";
import { failedWords } from "../model/console";
import { curlLine, noTokens, otlpLine, revokeQuestion, otlpOff, otlpTitle, shownOnce, tokenLine, tokensFoot, tokensTitle } from "../model/readApi";

export function ReadAPIPage({ store, down }: { store: Store; down: boolean }) {
  const state = useSignal<ReadAPI | null>(null);
  const problem = useSignal<string | null>(null);
  const name = useSignal("");
  const made = useSignal<ReadTokenMade | null>(null);
  const busy = useSignal(false);
  const load = async () => {
    try {
      state.value = await store.link.call("readApi/list", {});
      problem.value = null;
    } catch (error) {
      problem.value = failedWords(error);
    }
  };
  useEffect(() => { if (!down) void load(); }, [down]);
  const run = async (work: () => Promise<void>) => {
    busy.value = true;
    try {
      await work();
      problem.value = null;
    } catch (error) {
      problem.value = failedWords(error);
    } finally {
      busy.value = false;
    }
  };
  const make = () => run(async () => {
    made.value = await store.link.call("readApi/make", { name: name.value });
    name.value = "";
    await load();
  });
  const revoke = (id: string) => run(async () => {
    state.value = await store.link.call("readApi/revoke", { id });
    if (made.value?.token.id === id) made.value = null;
  });
  const now = state.value;
  if (!now) return <p class="hint" role={problem.value ? "alert" : undefined}>{problem.value ?? "Loading…"}</p>;
  return (
    <>
      <section aria-labelledby="read-api-tokens">
        <h3 class="section-head" id="read-api-tokens">{tokensTitle}</h3>
        {problem.value && <p class="hint" role="alert">{problem.value}</p>}
        <p class="small">Reads from <code>{now.url}</code></p>
        {made.value && (
          <div class="read-token-made" role="status">
            <p class="small strong">{shownOnce}</p>
            <code class="read-token-value">{made.value.value}</code>
            <p class="quiet small"><code>{curlLine(made.value.url, made.value.value)}</code></p>
            <div class="sheet-actions">
              <button type="button" onClick={() => void navigator.clipboard.writeText(made.value?.value ?? "").catch(() => {})}>Copy Token</button>
              <button type="button" onClick={() => { made.value = null; }}>Done</button>
            </div>
          </div>
        )}
        {now.tokens.length === 0 ? <p class="hint">{noTokens}</p> : (
          <ul class="request-list">
            {now.tokens.map((t) => (
              <li key={t.id} class={`request${t.revoked ? " quiet" : ""}`}>
                <span><span class="strong">{t.name}</span><br /><span class="quiet small">{tokenLine(t)}</span></span>
                {!t.revoked && (
                  <span class="request-actions">
                    <button type="button" class="destructive" disabled={down || busy.value} onClick={() => { if (window.confirm(revokeQuestion(t.name))) void revoke(t.id); }}>Revoke…</button>
                  </span>
                )}
              </li>
            ))}
          </ul>
        )}
        <form class="org-policy" onSubmit={(e) => { e.preventDefault(); void make(); }}>
          <label class="setting">
            <span>Name</span>
            <input type="text" spellcheck={false} aria-label="Token name" placeholder="Looker" value={name.value} disabled={down || busy.value}
              onInput={(e) => { name.value = (e.currentTarget as HTMLInputElement).value; }} />
          </label>
          <div class="sheet-actions">
            <button type="submit" class="prominent" disabled={down || busy.value || name.value.trim() === ""}>Make Token</button>
          </div>
        </form>
        <p class="hint">{tokensFoot}</p>
      </section>
      <section aria-labelledby="read-api-otlp">
        <h3 class="section-head" id="read-api-otlp">{otlpTitle}</h3>
        <p class="small">{now.otlp ? otlpLine(now.otlp) : otlpOff}</p>
      </section>
    </>
  );
}
