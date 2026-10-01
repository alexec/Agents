// What the page shows for each state of its connection (071 US1).
import type { Session } from "./session";
import { Paired } from "./views/Paired";
import { OtherControlPlane, Pairing, Unsupported } from "./views/Pairing";

export function App({ session }: { session: Session }) {
  const state = session.state.value;
  switch (state.kind) {
    case "loading":
    case "connecting":
      return <main class="pairing" aria-busy="true" />;
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
      return <Paired session={session} />;
  }
}
