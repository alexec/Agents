// Open in Browser (#109): the window or Agents Host opens the page at `#code=<code>` when this
// browser isn't paired, so it pairs in one step. The fragment never reaches a server, and it is
// taken out of the address before anything else reads it: imported first, so the router never
// sees it, and replaced at once, so the tab's address and Back hold no code. The code is the
// same one-use, five-minute browser code that is pasted, good only through this listener (R2).
import { type OIDCReturn, oidcReturn } from "./model/signIn";

export const linkedCode: string | null = take();

/**
 * Back from an org provider (#1002, FR-027): `#oidc-ticket=<t>`, or `#oidc-error=<code>&oidc-message=<words>`.
 * Taken out of the address at once, as a code is: a ticket pairs a browser once, within 2 minutes.
 */
export const oidcBack: OIDCReturn | null = takeOIDC();

function takeOIDC(): OIDCReturn | null {
  const back = oidcReturn(location.hash);
  if (back) history.replaceState(null, "", location.pathname + location.search);
  return back;
}

function take(): string | null {
  const match = /^#code=([^&#]+)$/.exec(location.hash);
  if (!match) return null;
  history.replaceState(null, "", location.pathname + location.search);
  try {
    return decodeURIComponent(match[1]!);
  } catch {
    return null;
  }
}
