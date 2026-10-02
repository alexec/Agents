// What a refused or failed action says (071 spec edge case: a refusal is never silent).
import { Failure } from "../protocol/generated";
import { CallFailed, LinkDown } from "../wire/link";

/** JSON-RPC's own "no such method": a host older than the page. */
export const methodNotFound = -32601;

/** Every paired browser may do everything (#111); only an older control plane or host still refuses by grant. */
export const notAllowed = "That isn't allowed from this browser. The Mac's Agents may need updating.";
export const notKnown = "That host can't do that yet. It may need updating.";

/** One sentence for the person: the refusal, the link, or the host's own words. */
export function describe(error: unknown): string {
  if (error instanceof CallFailed) {
    if (error.code === Failure.notPermitted) return notAllowed;
    if (error.code === methodNotFound) return notKnown;
    if (error.code === Failure.hostOffline) return "That host is offline. What's shown is from when it was last heard.";
    return error.message || "The host refused that.";
  }
  if (error instanceof LinkDown) return "The control plane isn't answering. Try again when it's back.";
  return "That didn't work.";
}

export { CallFailed, LinkDown };
