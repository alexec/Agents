// The page's only console writer (071 FR-033, research R12). It takes a fixed event name and,
// at most, a short code: never a line, a key, a code, a MAC or anything an agent said.

export type LogEvent =
  | "link.connecting" | "link.open" | "link.down" | "link.forgotten" | "link.refused"
  | "link.wrongControlPlane" | "link.unsupported" | "pair.ok" | "pair.fromLink" | "pair.failed" | "call.failed" | "call.timedOut";

/** `code` is a refusal reason, a JSON-RPC error number, or a close code. */
export function log(event: LogEvent, code?: string | number): void {
  console.info(code === undefined ? `agents: ${event}` : `agents: ${event} ${String(code).slice(0, 40)}`);
}
