// Frame F, left: the control plane can't be reached. What was shown stays, greyed out; sending
// is off and what is typed is kept (US7). The connection logic is wire/link.ts.
import { pageReadAt } from "../model/lastUpdate";
import type { Store } from "../model/store";
import { pairingWords, type Session } from "../session";
import { LastUpdate } from "./LastUpdate";
import { MessageBanner } from "./MessageKinds";

export function Banner({ session, store }: { session: Session; store: Store }) {
  // Refused as one tab too many (#2194): what to do, not "can't reach". A banner of the page
  // (docs/reference/design-system.md, "Messages"): neutral while it tries again by itself, attention
  // when the address refused and only the person can act.
  const state = session.state.value;
  const tryNow = <button type="button" onClick={() => session.link.retryNow()}>Try Now</button>;
  // How old what is shown is (#5141), after the banner's words.
  const readAt = pageReadAt(state, store.copyAt.value);
  const fresh = readAt !== undefined && <> <LastUpdate at={readAt} /></>;
  // Drawn from this device's copy (#4790) while the control plane is asked: what is shown may be old.
  if (state.kind === "connecting" || state.kind === "loading") {
    return <MessageBanner tone="neutral" name="banner"><strong>From this device.</strong> Connecting to the control plane.{fresh}</MessageBanner>;
  }
  if (state.kind === "down" && state.crowded) {
    return <MessageBanner tone="neutral" name="banner" actions={tryNow}><strong>{pairingWords.crowded}</strong> Trying again.{fresh}</MessageBanner>;
  }
  // The address itself refused the connection (suspended, over a plan's limit, 1003
  // CL-002, #2235): its own words, not "can't reach".
  if (state.kind === "down" && state.refusalLine) {
    const account = refusalLink(state.refusalLine);
    return (
      <MessageBanner tone="attention" name="banner" actions={<>
        {account && <a href={account} target="_blank" rel="noopener noreferrer">Open Account</a>}
        {tryNow}
      </>}><strong>{state.refusalLine}</strong></MessageBanner>
    );
  }
  return (
    <MessageBanner tone="neutral" name="banner" actions={tryNow}>
      <strong>Can't reach the control plane</strong> at {location.host}. Trying again.{fresh}
    </MessageBanner>
  );
}

// The account page a refusal's words name (#3153), offered as a link. Only https: the
// words come from outside.
export function refusalLink(line: string): string | undefined {
  const found = line.match(/https:\/\/[^\s]+/)?.[0].replace(/[.,;:!?)]+$/, "");
  return found && URL.canParse(found) ? found : undefined;
}
