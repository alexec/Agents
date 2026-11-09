// What the page shows for each state of its connection (071 US1).
import type { Store } from "./model/store";
import type { Session } from "./session";
import { Columns } from "./views/Columns";
import { OtherControlPlane, Pairing, Suspended, Unsupported } from "./views/Pairing";
import { TakeOverPage } from "./views/TakeOverPage";
import { route } from "./route";

export function App({ session, store }: { session: Session; store: Store }) {
  const state = session.state.value;
  switch (state.kind) {
    case "loading":
    case "connecting":
      // Said rather than blank (#114): a page waiting on its connection looked like one that
      // never loaded. The words wait a moment, so an ordinary connect doesn't flash them.
      return <main class="pairing" aria-busy="true"><p class="connecting" role="status">Connecting…</p></main>;
    case "unpaired":
    case "pairing":
    case "forgotten":
      return <Pairing session={session} />;
    case "unsupported":
      return <Unsupported />;
    case "suspended":
      // The person's org provider turned their access off (#1002, FR-029): this page and no other.
      return <Suspended paired={!state.unpaired} />;
    case "wrongControlPlane":
      return <OtherControlPlane session={session} />;
    case "open":
    case "down": {
      // A take-over tab (#4141): the agent browser or a simulator on the whole page, no columns.
      const r = route.value;
      if (r.takeOver && r.host && r.session) {
        return <TakeOverPage key={`${r.host}|${r.session}|${r.takeOver}`} store={store} host={r.host} session={r.session}
          source={r.takeOver} down={state.kind === "down"} />;
      }
      return <Columns session={session} store={store} />;
    }
  }
}
