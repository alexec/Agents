// What a refused or failed action says (071 spec edge case: a refusal is never silent).
import { Failure } from "../protocol/generated";
import { CallFailed, CallTimedOut, LinkDown } from "../wire/link";
import { compareVersions } from "./console";

/** JSON-RPC's own "no such method": a host older than the page. */
export const methodNotFound = -32601;
/** JSON-RPC's own "bad parameters": from an older host, a field it does not know (#4096). */
export const invalidParams = -32602;

/**
 * The versions the page last read (#4096): the control plane's, from `control/status`, which is
 * also the page's own, as the control plane serves it; and each machine's, from `machines/list`,
 * by the route a call goes on.
 */
const versions: { page?: string | undefined; machines: Map<string, string> } = { machines: new Map() };

export function knowVersions(page: string | undefined, machines: Iterable<[string, string]>): void {
  versions.page = page;
  versions.machines = new Map(machines);
}

/**
 * A missing method or bad parameters from a machine older than the page, in words; else undefined.
 * The machine's own words are not logged: the page logs only `call.failed` and the code (FR-033).
 */
export function olderMachine(error: CallFailed): string | undefined {
  if (error.code !== invalidParams && error.code !== methodNotFound) return undefined;
  const theirs = error.route ? versions.machines.get(error.route) : undefined;
  const ours = versions.page;
  if (!theirs || !ours || compareVersions(theirs, ours) >= 0) return undefined;
  return `This machine needs an update to do this. It runs Agents ${theirs}; this page is ${ours}.`;
}

/** Every paired browser may do everything (#111); only an older control plane or host still refuses by grant. */
export const notAllowed = "That isn't allowed from this browser. The Mac's Agents may need updating.";
export const notKnown = "That machine can't do that yet. It may need updating.";

/** One sentence for the person: the refusal, the link, or the host's own words. */
export function describe(error: unknown): string {
  if (error instanceof CallFailed) {
    if (error.code === Failure.notPermitted) return notAllowed;
    const older = olderMachine(error);
    if (older) return older;
    if (error.code === methodNotFound) return notKnown;
    if (error.code === Failure.hostOffline) return "That machine is offline. What's shown is from when it was last heard.";
    return error.message || "The machine refused that.";
  }
  // A slow call given up is not the control plane being down: it may still finish (#291).
  if (error instanceof CallTimedOut) return "That took too long. Try again.";
  if (error instanceof LinkDown) return "The control plane isn't answering. Try again when it's back.";
  return "That didn't work.";
}

export { CallFailed, CallTimedOut, LinkDown };
