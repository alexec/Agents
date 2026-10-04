// The lines a session's row has under its report, in the window's and the Remote's words (#251):
// what it holds or waits for (LeaseStatus, 036), what events it waits on (WaitStatus, 042), when
// an archived one retires (RetirementWords.rowNote, 051), who started it (028), and its
// worktree's help (WorktreeBadge). Worked out here, so the row only draws them.
import type { Agent, AgentWorktree, EventPattern, LeaseSnapshot, ResourceKind } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

/** LeaseWords.clock: "14:12". */
export function clock(date: Date): string {
  return `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}

/** LeaseWords.ordinal: "1st", "2nd", "11th". */
export function ordinal(n: number): string {
  const tens = Math.floor(n / 10) % 10, units = n % 10;
  const suffix = tens === 1 ? "th" : units === 1 ? "st" : units === 2 ? "nd" : units === 3 ? "rd" : "th";
  return `${n}${suffix}`;
}

/** LeaseWords.agentName: its title in quotes, or "another agent". */
export function agentName(title: string | undefined): string {
  const trimmed = title?.trim();
  return trimmed ? `“${trimmed}”` : "another agent";
}

/** LeaseLimits.warning: a lease is ending soon in its last five minutes. */
const warning = 5 * 60_000;

/** LeaseStatus.shortName: what a row has room for. */
function shortName(displayName: string, kind: ResourceKind): string {
  if (kind === "screen") return "Screen";
  if (kind === "simulator") return displayName.split(" · ")[0] ?? displayName;
  return displayName;
}

/** LeaseMark: the first lease or wait in short, how many more, the whole of it, and one capsule each. */
export interface LeaseMark { mark: string; more: number; full: string; capsules: string[] }

/** LeaseStatus.of, then its mark: nothing when the agent holds and waits for nothing. */
export function leaseMark(agentID: string, snapshot: LeaseSnapshot | undefined,
  title: (id: string) => string | undefined): LeaseMark | null {
  if (!snapshot) return null;
  const now = fromWireDate(snapshot.at).getTime();
  const holding: { short: string; display: string; expires: Date; minutes: number; soon: boolean }[] = [];
  const waiting: { short: string; display: string; holder: string; until?: Date; place: number }[] = [];
  for (const state of snapshot.resources) {
    const holds = state.holds ?? (state.lease ? [state.lease] : []);
    const short = shortName(state.displayName, state.kind);
    const lease = holds.find((l) => l.holder === agentID);
    if (lease) {
      const expires = fromWireDate(lease.expiresAt);
      const left = expires.getTime() - now;
      holding.push({ short, display: state.displayName, expires, minutes: Math.max(0, Math.ceil(left / 60_000)),
        soon: left > 0 && left <= warning });
    }
    const index = state.line.findIndex((m) => m.agentID === agentID);
    if (index >= 0) {
      const next = [...holds].sort((a, b) => a.expiresAt - b.expiresAt)[0];
      waiting.push({ short, display: state.displayName, holder: agentName(next ? title(next.holder) : undefined),
        ...(next ? { until: fromWireDate(next.expiresAt) } : {}), place: index + 1 });
    }
  }
  if (holding.length === 0 && waiting.length === 0) return null;
  const first = holding[0];
  const mark = first ? `▣ Holds ${first.short} · ${first.minutes} min${first.soon ? " left" : ""}`
    : `◷ Waiting for ${waiting[0]!.short} · ${ordinal(waiting[0]!.place)} in line`;
  const full = [
    ...holding.map((h) => `Holding ${h.display}, ${h.minutes} min left, until ${clock(h.expires)}`),
    ...waiting.map((w) => `Waiting for ${w.display}, held by ${w.holder}${w.until ? ` until ${clock(w.until)}` : ""}, ${ordinal(w.place)} in line`),
  ].join(". ") + ".";
  // LeaseStatus.capsules: holdings first, for the chat's row over the prompt.
  const capsules = [
    ...holding.map((h) => `\u25A3 ${h.short} \u00B7 ${h.minutes} min${h.soon ? " left" : ""}`),
    ...waiting.map((w) => `\u25F7 Waiting for ${w.short} \u00B7 held by ${w.holder}${w.until ? ` until ${clock(w.until)}` : ""} \u00B7 ${ordinal(w.place)}`),
  ];
  return { mark, more: holding.length + waiting.length - 1, full, capsules };
}

/** WaitStatus.finishing: "“A” to finish", "“A” and “B” to finish". */
function finishing(names: string[]): string {
  const quoted = names.map((n) => `“${n}”`);
  if (quoted.length === 1) return `${quoted[0]} to finish`;
  if (quoted.length === 2) return `${quoted[0]} and ${quoted[1]} to finish`;
  return `${quoted.slice(0, -1).join(", ")} and ${quoted[quoted.length - 1]} to finish`;
}

/** EventPattern.label: the name with its filters, "agent.finished outcome done|nothing_to_do". */
function patternLabel(pattern: EventPattern): string {
  const keys = [...new Set([...Object.keys(pattern.filters), ...Object.keys(pattern.anyOf ?? {})])].sort();
  return [pattern.name, ...keys.map((key) => `${key} ${pattern.anyOf?.[key]?.join("|") ?? pattern.filters[key]}`)].join(" ");
}

/** The one value a filter has, if it has one. */
function single(pattern: EventPattern, key: string): string | undefined {
  const values = pattern.anyOf?.[key] ?? (pattern.filters[key] !== undefined ? pattern.filters[key]!.split("|") : []);
  return values.length === 1 ? values[0] : undefined;
}

/**
 * WaitStatus.of(…).line and EventWords.hint for a wait on events, for the chat's capsule over the
 * prompt: "◷ Waiting for … · since 23:30 · until 09:00", and that sending takes its place.
 */
export function eventWaitCapsule(agent: Agent, title: (id: string) => string | undefined): { line: string; hint: string } | null {
  const wait = agent.eventWait;
  const mark = eventWaitMark(agent, title);
  if (!wait || !mark) return null;
  let line = `${mark} \u00B7 since ${clock(fromWireDate(wait.since))}`;
  if (wait.deadline !== undefined) line += ` \u00B7 until ${clock(fromWireDate(wait.deadline))}`;
  return { line, hint: `Sending will cancel the wait on ${wait.patterns.map(patternLabel).join(" or ")}.` };
}

/** WaitStatus.of(…).mark for a wait on events: "◷ Waiting for “Fix login” to finish". A block's is blockLines'. */
export function eventWaitMark(agent: Agent, title: (id: string) => string | undefined): string | null {
  const wait = agent.eventWait;
  if (!wait || wait.ending !== undefined) return null;
  const agents = wait.patterns.map((p) => {
    const id = p.name === "agent.finished" && Object.keys(p.anyOf ?? p.filters).length === 1 ? single(p, "agent") : undefined;
    return id === undefined ? undefined : title(id) ?? id;
  });
  const what = agents.length > 0 && agents.every((a) => a !== undefined)
    ? finishing(agents as string[]) : wait.patterns.map(patternLabel).join(" or ");
  return `◷ Waiting for ${what}`;
}

/**
 * RetirementWords.rowNote: when an archived agent retires, or why it is kept. The page doesn't
 * hold the retention limit, so the next-to-go note names "the limit", as the window's does
 * before it has read it.
 */
export function retirementNote(agent: Agent, now = new Date()): string | null {
  if (agent.state !== "archived") return null;
  const retirement = agent.retirement;
  if (!retirement) return null;
  if ("at" in retirement) {
    const day = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
    const days = Math.round((day(fromWireDate(retirement.at)) - day(now)) / 86_400_000);
    if (days <= 0) return "Retires today";
    if (days === 1) return "Retires tomorrow";
    return `Retires in ${days} days`;
  }
  if ("nextUnderCap" in retirement) return "Next to be retired to stay under the limit";
  if ("held" in retirement) {
    if (retirement.held === "worktreeHasWork") return "Kept: its worktree has work in it";
    if (retirement.held === "workflowRunning") return "Kept: a workflow run is still going";
  }
  return null;
}

/** AgentsModel.startedByAgentLabel: who started an agent another agent started. */
export function startedByAgentLabel(agent: Agent, title: (id: string) => string | undefined): string | null {
  if (!agent.startedByAgent) return null;
  const name = title(agent.startedByAgent)?.trim();
  return `Started by ${name ? `“${name}”` : "another agent"}`;
}

/** WorktreeBadge's help: "branch — path", and that it is gone. */
export function worktreeHelp(worktree: AgentWorktree, gone: boolean): string {
  let path: string = worktree.root;
  try { path = decodeURIComponent(new URL(worktree.root).pathname); } catch { /* as written */ }
  const branch = worktree.branch ?? "detached";
  return gone ? `${branch} — ${path}, which is not there any more` : `${branch} — ${path}`;
}
