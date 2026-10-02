// What the page shows for each state of its connection (071 US1).
import type { Store } from "./model/store";
import type { Session } from "./session";
import { Columns } from "./views/Columns";
import { OtherControlPlane, Pairing, Unsupported } from "./views/Pairing";

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
    case "wrongControlPlane":
      return <OtherControlPlane session={session} />;
    case "open":
    case "down":
      return <Columns session={session} store={store} />;
  }
}
