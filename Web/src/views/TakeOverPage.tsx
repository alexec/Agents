// The take-over tab (#4141; the window's take-over window): the session's agent browser or a
// simulator on the whole page, opened by Open on a live tile or Open the page on a hand_to_person
// card. Its own tab, one per session and source, so the person uses the page while the chat stays
// where it was. The browser watches (browser/watch) while the tab is on screen, so frames come
// whoever drives. A hand-off's step and its Done and Can't do it are above the page.
import { Fragment } from "preact";
import type { Store } from "../model/store";
import type { TakeOver } from "../route";
import { Capability } from "../protocol/capabilities.generated";
import { hostNeedsUpdate } from "../model/capabilities";
import { tileBrowser, tileSimulator } from "../model/liveTileWords";
import { AgentBrowserPane } from "./AgentBrowserPane";
import { SimulatorPane } from "./SimulatorPane";
import { useWaitingCards } from "./Cards";

export function TakeOverPage({ store, host, session, source, down }: {
  store: Store; host: string; session: string; source: TakeOver; down: boolean;
}) {
  const agent = store.agent(host, session);
  const kind = source === "browser" ? tileBrowser : tileSimulator;
  return (
    <div class={`app take-over${down ? " down" : ""}`}>
      <header class="column-head take-over-head">
        <h1>{agent?.title ?? "Session"}</h1>
        <span class="quiet">{kind}</span>
      </header>
      {source === "browser"
        ? (store.has(host, Capability.browser1)
          ? <BrowserTakeOver store={store} host={host} session={session} down={down} />
          : <p class="hint take-over-page">{hostNeedsUpdate}</p>)
        : <div class="take-over-page">
          {store.has(host, Capability.simulators1)
            ? <SimulatorPane store={store} host={host} />
            : <p class="hint">{hostNeedsUpdate}</p>}
        </div>}
    </div>
  );
}

/** The agent browser, with the session's hand-off above it: the page is open, so no Open the page. */
function BrowserTakeOver({ store, host, session, down }: { store: Store; host: string; session: string; down: boolean }) {
  const handOffs = useWaitingCards({ store, host, session, down, handOffsOnly: true });
  return (
    <>
      {handOffs.length > 0 && (
        <div class="take-over-hand-off" aria-label="Waiting for you">
          {handOffs.map((card) => <Fragment key={card.key}>{card.node}</Fragment>)}
        </div>
      )}
      <div class="take-over-page">
        <AgentBrowserPane key={session} store={store} host={host} session={session} />
      </div>
    </>
  );
}
