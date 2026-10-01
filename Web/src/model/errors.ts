// What a refused or failed action says (071 spec edge case: a refusal by grant is never silent).
import { Failure } from "../protocol/generated";
import { CallFailed, LinkDown } from "../wire/link";

/** JSON-RPC's own "no such method", which is what a host says to a method a grant can't reach. */
export const methodNotFound = -32601;

export const notAllowedByGrant = "This browser's grant doesn't allow that.";

/** One sentence for the person: the grant, the link, or the host's own words. */
export function describe(error: unknown): string {
  if (error instanceof CallFailed) {
    if (error.code === Failure.notPermitted || error.code === methodNotFound) return notAllowedByGrant;
    if (error.code === Failure.hostOffline) return "That host is offline. What's shown is from when it was last heard.";
    return error.message || "The host refused that.";
  }
  if (error instanceof LinkDown) return "The control plane isn't answering. Try again when it's back.";
  return "That didn't work.";
}

export { CallFailed, LinkDown };
