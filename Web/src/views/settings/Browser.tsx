// Settings ▸ Machines ▸ Browser (#3535): the machine's browser (#3533), its sites with sign-ins, Clear for
// one or all, and the size of the Chromium download. Listed in ./sections.ts. Reading the sites starts
// Chromium on the machine when it is downloaded and not running.
import { signal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { BrowserState } from "../../protocol/generated";
import type { Store } from "../../model/store";
import { describe } from "../../model/errors";
import { browserWords, clearSiteWords, cookiesWords, downloadWords, sitesNote } from "../../model/browserSettings";
import { useSettingsMachine } from "./SettingsMachine";

const states = signal<Record<string, BrowserState | null>>({});
const clearing = signal(false);

export function BrowserSection({ store, down }: { store: Store; down: boolean }) {
  const { host, picker } = useSettingsMachine(store);
  useEffect(() => {
    if (!host) return;
    void store.link.call("browser/state", {}, host).then(
      (state) => { states.value = { ...states.value, [host]: state }; },
      // A host too old to know the method: the section stays out.
      () => { states.value = { ...states.value, [host]: null }; },
    );
  }, [store, host]);
  const state = host ? states.value[host] : undefined;
  if (state === null) return null;
  const clear = async (site?: string) => {
    if (!host) return;
    if (site === undefined && !window.confirm(`${browserWords.clearAllQuestion} ${browserWords.clearAllDetail}`)) return;
    clearing.value = true;
    try {
      const cleared = await store.link.call("browser/clear", site === undefined ? {} : { site }, host);
      states.value = { ...states.value, [host]: cleared };
    } catch (error) {
      store.say(describe(error));
    } finally {
      clearing.value = false;
    }
  };
  const note = state ? sitesNote(state) : null;
  const busy = down || clearing.value;
  return (
    <section aria-labelledby="settings-browser">
      <h3 class="section-head" id="settings-browser">{browserWords.title}</h3>
      {picker}
      <h4 class="small">{browserWords.sitesHeader}</h4>
      {!state ? <p class="hint">Loading…</p> : note ? <p class="hint">{note}</p> : null}
      {state?.installed && state.sites.map((s) => (
        <div class="setting" key={s.site}>
          <span>{s.site} <span class="faint small">{cookiesWords(s.cookies)}</span></span>
          <button type="button" aria-label={clearSiteWords(s.site)} disabled={busy} onClick={() => void clear(s.site)}>{browserWords.clear}</button>
        </div>
      ))}
      {state?.installed && state.sites.length > 1 && (
        <div class="setting">
          <span />
          <button type="button" disabled={busy} onClick={() => void clear()}>{browserWords.clearAll}</button>
        </div>
      )}
      <p class="hint">{browserWords.sitesFooter}</p>
      <h4 class="small">{browserWords.downloadHeader}</h4>
      <div class="setting">
        <span>{browserWords.downloadLabel}</span>
        <span class="quiet">{state ? downloadWords(state) : ""}</span>
      </div>
      <p class="hint">{browserWords.downloadFooter}</p>
    </section>
  );
}
