// Console ▸ Read API (#2019, #1804 decision 4): the tokens a BI tool reads the reports with,
// and the OTLP exporter's state. The words apart from the view, so the tests read them.
import type { OTLPExport, ReadToken } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { when } from "./orgPolicy";

export const tokensTitle = "Tokens";
export const otlpTitle = "OTLP Exporter";
export const noTokens = "No tokens yet. Make one for each tool that reads the reports.";
export const tokensFoot = "A token reads the organisation's reports and nothing else, at most 30 times a minute. It stops when you revoke it, or when the admin who made it is an admin no longer.";
export const otlpOff = "Off. To send today's figures by runtime to an OpenTelemetry collector, set OTEL_EXPORTER_OTLP_ENDPOINT on agents-control and start it again.";
/** What Revoke… asks first (#2438): a revoked token cannot be brought back. */
export function revokeQuestion(name: string): string {
  return `Revoke ${name}? The tool that reads the reports with it stops at once, and a revoked token cannot be brought back.`;
}
export const shownOnce = "Copy it now. It is not shown again.";

/** The curl line that reads a month of the reports as CSV with the token. */
export function curlLine(url: string, value: string): string {
  return `curl -H 'Authorization: Bearer ${value}' '${url}?range=month&format=csv'`;
}

/** A token's grey line: who made it when, and its last use or its revoke. */
export function tokenLine(t: ReadToken, now: Date = new Date()): string {
  const by = t.made.by.userName ?? t.made.by.user;
  const made = `Made by ${by} ${when(fromWireDate(t.made.at), now)}.`;
  if (t.revoked) return `${made} Revoked ${when(fromWireDate(t.revoked.at), now)}.`;
  if (t.lastUse) return `${made} Last used ${when(fromWireDate(t.lastUse.at), now)}${t.lastUse.address ? ` from ${t.lastUse.address}` : ""}.`;
  return `${made} Not used yet.`;
}

/** The exporter's line: where it sends, how often, and how the last send went. */
export function otlpLine(o: OTLPExport, now: Date = new Date()): string {
  const every = o.every % 60 === 0 ? `${o.every / 60} min` : `${o.every} s`;
  const head = `Sends today's figures by runtime to ${o.endpoint} every ${every}.`;
  const sent = o.lastSent ? fromWireDate(o.lastSent) : null;
  const failed = o.failedAt ? fromWireDate(o.failedAt) : null;
  if (failed && (!sent || failed > sent)) return `${head} The last send failed ${when(failed, now)}: ${o.lastFailure ?? "no answer"}.`;
  if (sent) return `${head} Last sent ${when(sent, now)}.`;
  return `${head} Not sent yet: the first goes a minute after start.`;
}
