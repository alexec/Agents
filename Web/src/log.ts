// The page's only console writer (071 FR-033, research R12). It takes a fixed event name and,
// at most, a short code: never a line, a key, a code, a MAC or anything an agent said.

export type LogEvent =
  | "link.connecting" | "link.open" | "link.down" | "link.forgotten" | "link.refused"
  | "link.wrongControlPlane" | "link.unsupported" | "link.newKey" | "pair.ok" | "pair.fromLink" | "pair.failed" | "call.failed" | "call.timedOut"
  // Org identity (#1002): a suspension, and the org sign-in.
  | "link.suspended" | "pair.ask" | "pair.org" | "pair.orgFailed" | "pair.suspended" | "signIn.orgStart" | "signIn.providersFailed";

/** `code` is a refusal reason, a JSON-RPC error number, or a close code. */
export function log(event: LogEvent, code?: string | number): void {
  console.info(code === undefined ? `agents: ${event}` : `agents: ${event} ${String(code).slice(0, 40)}`);
}
