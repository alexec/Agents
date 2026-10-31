// Where the audit is sent (#1001): Console ▸ Audit ▸ Sinks, an admin's. Each audit entry also goes
// to each sink as the control plane writes it: syslog (RFC 5424 over TCP or TLS) or HTTP (a POST of
// JSON lines). A token is only ever sent; the control plane answers whether there is one.
import type { AuditSink, AuditSinkKind, AuditSinkStatus } from "../protocol/generated";

/** One row being edited: the token typed, or "" to keep the one there. */
export type SinkDraft = { kind: AuditSinkKind; address: string; token: string; hasToken: boolean };

export const sinksMost = 4;

export const sinksHint = "Each audit entry also goes to these places as it is written: syslog over TCP or TLS, "
  + "or HTTP as JSON lines.";

/** The address field's example, by kind. */
export function addressPlaceholder(kind: AuditSinkKind): string {
  return kind === "syslog" ? "tls://host:port" : "An https address";
}

export function draftsOf(sinks: readonly AuditSinkStatus[]): SinkDraft[] {
  return sinks.map(({ sink }) => ({ kind: sink.kind, address: sink.address, token: "", hasToken: sink.hasToken === true }));
}

/** What audit/setSinks takes: a token only where one was typed, and none for syslog. */
export function sinksToSet(drafts: readonly SinkDraft[]): AuditSink[] {
  return drafts.filter((d) => d.address.trim() !== "").map((d) => {
    const sink: AuditSink = { kind: d.kind, address: d.address.trim() };
    if (d.kind === "http" && d.token.trim() !== "") sink.token = d.token.trim();
    return sink;
  });
}

/** How a sink is sending, in a line: the last sent, what waits, what was dropped, the last failure. */
export function sinkStatusLine(s: AuditSinkStatus, now = new Date()): string {
  const parts: string[] = [];
  if (s.lastError) parts.push(`Not sent: ${s.lastError}`);
  else if (s.sentAt) parts.push(`Sent ${ago(new Date(s.sentAt), now)}`);
  else parts.push("Nothing sent yet");
  if (s.queued > 0) parts.push(`${s.queued.toLocaleString("en")} waiting`);
  if (s.dropped > 0) parts.push(`${s.dropped.toLocaleString("en")} dropped when the queue was full`);
  return parts.join(" · ");
}

function ago(at: Date, now: Date): string {
  const seconds = Math.max(0, Math.round((now.getTime() - at.getTime()) / 1000));
  if (seconds < 60) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return minutes === 1 ? "a minute ago" : `${minutes} minutes ago`;
  const hours = Math.round(minutes / 60);
  return hours === 1 ? "an hour ago" : `${hours} hours ago`;
}
