// Frame F, left: the control plane can't be reached. What was shown stays, greyed out; sending
// is off and what is typed is kept (US7). The connection logic is wire/link.ts.
import { pairingWords, type Session } from "../session";

export function Banner({ session }: { session: Session }) {
  // Refused as one tab too many (#2194): what to do, not "can't reach".
  const state = session.state.value;
  if (state.kind === "down" && state.crowded) {
    return (
      <div class="banner" role="status">
        <span>⚠︎ <strong>{pairingWords.crowded}</strong> Trying again.</span>
        <button onClick={() => session.link.retryNow()}>Try Now</button>
      </div>
    );
  }
  return (
    <div class="banner" role="status">
      <span>⚠︎ <strong>Can't reach the control plane</strong> at {location.host}. Trying again.</span>
      <button onClick={() => session.link.retryNow()}>Try Now</button>
    </div>
  );
}
