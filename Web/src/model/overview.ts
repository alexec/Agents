// The Overview's words (#2141): the page the control plane web page opens on. Five cards, each
// from what the page already holds, with a link to the section that has all of it.
import type { Agent, ControlMachine, FolderSummary, ReportRow } from "../protocol/generated";
import { sessionMark } from "./sidebar";
import { byStart } from "./groups";

/** A live session and where it is. */
export interface Placed { host: ControlMachine; folder: FolderSummary; agent: Agent }

/** Every live session in every folder not put away, on every machine. */
export function placedSessions(hosts: readonly ControlMachine[], folders: Record<string, FolderSummary[] | undefined>,
  sessionsIn: (host: string, folder: string) => readonly Agent[]): Placed[] {
  return hosts.flatMap((host) => (folders[host.id] ?? []).filter((f) => f.folder.archivedAt === undefined)
    .flatMap((folder) => sessionsIn(host.id, folder.folder.folder).map((agent) => ({ host, folder, agent }))));
}

/** The sessions that need the person: a question or an OK. Newest started first. */
export function needingYou(list: readonly Placed[]): Placed[] {
  return list.filter((p) => sessionMark(p.agent) === "needsYou").sort((a, b) => byStart(a.agent, b.agent));
}

/** The sessions working now, a tool or thinking. Newest started first. */
export function workingNow(list: readonly Placed[]): Placed[] {
  return list.filter((p) => { const m = sessionMark(p.agent); return m === "working" || m === "tool"; })
    .sort((a, b) => byStart(a.agent, b.agent));
}

/** "6 agents on 2 machines", "1 agent on 1 machine", or "Nothing runs now." */
export function workingWords(list: readonly Placed[]): string {
  if (list.length === 0) return nothingRuns;
  const machines = new Set(list.map((p) => p.host.id)).size;
  return `${list.length === 1 ? "1 agent" : `${list.length} agents`} on ${machines === 1 ? "1 machine" : `${machines} machines`}`;
}

/** "2 sessions · 3 requests", or what waits when only one kind does. */
export function waitingWords(sessions: number, requests: number | null): string {
  const parts: string[] = [];
  if (sessions > 0) parts.push(sessions === 1 ? "1 session" : `${sessions} sessions`);
  if (requests !== null && requests > 0) parts.push(requests === 1 ? "1 request" : `${requests} requests`);
  return parts.length ? parts.join(" · ") : nothingWaits;
}

/** A report's rows added up by currency. */
export function rowsCost(rows: readonly ReportRow[]): Record<string, number> {
  const total: Record<string, number> = {};
  for (const row of rows) for (const [c, v] of Object.entries(row.cost)) total[c] = (total[c] ?? 0) + v;
  return total;
}

/** The folder a session is in, by name, for a row: "api", or "build-01: api" on another machine. */
export function placeWords(p: Placed, several: boolean): string {
  return several ? `${p.host.name}: ${p.folder.name}` : p.folder.name;
}

export const overviewIntro = "What runs on this control plane now, and what waits for you.";
export const nothingRuns = "Nothing runs now.";
export const nothingWaits = "Nothing waits for you.";
export const noEvents = "Nothing has happened yet.";
export const noSpend = "Nothing spent today.";
/** How many rows a card lists before its link to the rest. */
export const cardRows = 5;
export const eventRows = 10;
