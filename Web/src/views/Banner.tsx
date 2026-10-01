// Frame F, left: the control plane can't be reached. What was shown stays, greyed out; sending
// is off and what is typed is kept (US7). The connection logic is wire/link.ts.
import type { Session } from "../session";

export function Banner({ session }: { session: Session }) {
  return (
    <div class="banner" role="status">
      <span>⚠︎ <strong>Can't reach the control plane</strong> at {location.host}. Trying again.</span>
      <button onClick={() => session.link.retryNow()}>Try Now</button>
    </div>
  );
}
