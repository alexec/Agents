// The lines a session's row has under its report, in the window's and the Remote's words (#251):
// what it holds or waits for (LeaseStatus, 036), what events it waits on (WaitStatus, 042), who
// started it (028), and its worktree's help (WorktreeBadge). Worked out here, so the row only draws them.
import type { Agent, AgentWorktree, EventPattern, EventWait, LeaseSnapshot, MCPEventTrigger, ResourceKind } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { eventMeaning } from "./workflows";

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

/**
 * LeaseMark: the first lease or wait in short, how many more, the whole of it, and one line each;
 * then LeaseStatus.holdingOnly's mark for a row (#582), and each wait by name and in full for its wait line.
 */
export interface LeaseMark {
  mark: string; more: number; full: string; lines: string[];
  holds: { mark: string; more: number; full: string } | null;
  waitingNames: string[]; waitingFull: string[];
}

/** LeaseStatus.Waiting: a place in a resource's line. */
interface Place { short: string; display: string; holder: string; until?: Date; place: number }

/** The agent's place in one resource's line, if it has one. */
function placeIn(state: LeaseSnapshot["resources"][number], agentID: string,
  title: (id: string) => string | undefined): Place | null {
  const holds = state.holds ?? (state.lease ? [state.lease] : []);
  const index = state.line.findIndex((m) => m.agentID === agentID);
  if (index < 0) return null;
  const next = [...holds].sort((a, b) => a.expiresAt - b.expiresAt)[0];
  return { short: shortName(state.displayName, state.kind), display: state.displayName,
    holder: agentName(next ? title(next.holder) : undefined),
    ...(next ? { until: fromWireDate(next.expiresAt) } : {}), place: index + 1 };
}

/**
 * EventWait.lineResource: the resource whose line the agent's open wait is a place in (#2361), a
 * wait on lease.granted narrowed to it and one resource; undefined for any other wait.
 */
export function lineResource(agent: Agent): string | undefined {
  const wait = agent.eventWait;
  if (!wait || wait.ending !== undefined || wait.patterns.length !== 1) return undefined;
  const pattern = wait.patterns[0]!;
  const keys = new Set([...Object.keys(pattern.filters), ...Object.keys(pattern.anyOf ?? {})]);
  if (pattern.name !== "lease.granted" || keys.size !== 2 || single(pattern, "agent") === undefined) return undefined;
  return single(pattern, "resource");
}

/** The agent's place in the line its wait is for, from the daemon's leases. */
function linePlace(agent: Agent, resource: string, snapshot: LeaseSnapshot | undefined,
  title: (id: string) => string | undefined): Place | null {
  const state = snapshot?.resources.find((r) => r.name === resource);
  return state ? placeIn(state, agent.id, title) : null;
}

/**
 * LeaseStatus.of, then its mark: nothing when the agent holds and waits for nothing. `without` is
 * the resource whose place in line the agent's wait card says already (#2361), left out here.
 */
export function leaseMark(agentID: string, snapshot: LeaseSnapshot | undefined,
  title: (id: string) => string | undefined, without?: string): LeaseMark | null {
  if (!snapshot) return null;
  const now = fromWireDate(snapshot.at).getTime();
  const holding: { short: string; display: string; expires: Date; minutes: number; soon: boolean }[] = [];
  const waiting: Place[] = [];
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
    const place = state.name === without ? null : placeIn(state, agentID, title);
    if (place) waiting.push(place);
  }
  if (holding.length === 0 && waiting.length === 0) return null;
  const first = holding[0];
  const mark = first ? `▣ Holds ${first.short} · ${first.minutes} min${first.soon ? " left" : ""}`
    : `◷ Waiting for ${waiting[0]!.short} · ${ordinal(waiting[0]!.place)} in line`;
  const held = holding.map((h) => `Holding ${h.display}, ${h.minutes} min left, until ${clock(h.expires)}`);
  const waitingFull = waiting.map((w) => `Waiting for ${w.display}, held by ${w.holder}${w.until ? ` until ${clock(w.until)}` : ""}, ${ordinal(w.place)} in line`);
  const full = [...held, ...waitingFull].join(". ") + ".";
  // LeaseStatus.lines: holdings first, for the chat's foot with the working line (#2344).
  const lines = [
    ...holding.map((h) => `\u25A3 ${h.short} \u00B7 ${h.minutes} min${h.soon ? " left" : ""}`),
    ...waiting.map((w) => `\u25F7 Waiting for ${w.short} \u00B7 held by ${w.holder}${w.until ? ` until ${clock(w.until)}` : ""} \u00B7 ${ordinal(w.place)}`),
  ];
  return { mark, more: holding.length + waiting.length - 1, full, lines,
    holds: first ? { mark, more: holding.length - 1, full: held.join(". ") + "." } : null,
    waitingNames: waiting.map((w) => w.short), waitingFull };
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
 * WaitStatus.of(…).line for a wait on events, for the chat's wait card (#1995): "◷ Waiting for … ·
 * since 23:30 · until 09:00".
 */
export function eventWaitLine(agent: Agent, title: (id: string) => string | undefined,
  snapshot?: LeaseSnapshot): string | null {
  // A place in a lease's line, as the line says it (#2361).
  const resource = lineResource(agent);
  if (resource !== undefined) {
    const place = linePlace(agent, resource, snapshot, title);
    return place
      ? `◷ Waiting for ${place.display} \u00B7 held by ${place.holder}${place.until ? ` until ${clock(place.until)}` : ""} \u00B7 ${ordinal(place.place)} in line`
      : `◷ Waiting for your turn with ${resource}`;
  }
  const wait = agent.eventWait;
  const mark = eventWaitMark(agent, title);
  if (!wait || !mark) return null;
  let line = `${mark} \u00B7 since ${clock(fromWireDate(wait.since))}`;
  if (wait.deadline !== undefined) line += ` \u00B7 until ${clock(fromWireDate(wait.deadline))}`;
  return line;
}

/** EventWait.carryOnPrompt: what Continue sends, as the person (#3052). */
export const eventCarryOnPrompt = "I've stopped waiting for the event. Carry on.";

/** The event wait card's readable lines, with its timeout and elapsed minutes (#2565). */
export function eventWaitCardLines(agent: Agent, title: (id: string) => string | undefined,
  now: Date): string[] | null {
  const wait = agent.eventWait;
  if (!wait || wait.ending !== undefined || wait.deadline === undefined || lineResource(agent) !== undefined) return null;
  const mark = eventWaitMark(agent, title);
  if (!mark) return null;
  const since = fromWireDate(wait.since);
  const deadline = fromWireDate(wait.deadline);
  const duration = Math.max(1, Math.ceil((deadline.getTime() - since.getTime()) / 60_000));
  const elapsed = Math.max(0, Math.floor((now.getTime() - since.getTime()) / 60_000));
  return [`Waiting for ${duration} min for:`, mark.replace(/^◷ Waiting for /, ""), `${elapsed} min elapsed so far.`];
}

/**
 * The event wait card's minutes and bar (#2843): elapsed and, with a deadline, the timeout and how
 * far through it the wait is, 0–100. The wire's dates are seconds since 2001, not 1970.
 */
export function eventWaitMinutes(wait: EventWait, now: Date): { elapsed: number; total?: number; percent?: number } {
  const since = fromWireDate(wait.since).getTime();
  const elapsed = Math.max(0, Math.floor((now.getTime() - since) / 60_000));
  if (wait.deadline === undefined) return { elapsed };
  const deadline = fromWireDate(wait.deadline).getTime();
  const total = Math.max(1, Math.ceil((deadline - since) / 60_000));
  const percent = deadline > since ? Math.min(100, Math.max(0, (now.getTime() - since) / (deadline - since) * 100)) : 100;
  return { elapsed, total, percent };
}

export interface EventWaitSummaryLine {
  id: string;
  source: string;
  /** The events' names, as the wait has them, for the line's title. */
  events: string[];
  /** What the events mean, joined with "or". */
  words: string;
  arguments: string[];
  /** MCPEventTrigger.url: the PR or issue its arguments name, as a link (#3077). */
  url: string | undefined;
}

/**
 * MCPEventTrigger.url (#3077): built from `repo` or `project` and `pr` or `issue`,
 * assuming github.com or gitlab.com — the trigger carries no host, so a GitHub
 * Enterprise or a self-managed GitLab's own base URL cannot be told from this alone.
 */
export function triggerURL(trigger: MCPEventTrigger): string | undefined {
  const args = trigger.arguments;
  const repo = typeof args.repo === "string" ? args.repo : undefined;
  const project = typeof args.project === "string" ? args.project : undefined;
  const pr = typeof args.pr === "number" ? args.pr : undefined;
  const issue = typeof args.issue === "number" ? args.issue : undefined;
  if (repo !== undefined) {
    if (pr !== undefined) return `https://github.com/${repo}/pull/${pr}`;
    if (issue !== undefined) return `https://github.com/${repo}/issues/${issue}`;
  } else if (project !== undefined && project.includes("/")) {
    if (pr !== undefined) return `https://gitlab.com/${project}/-/merge_requests/${pr}`;
    if (issue !== undefined) return `https://gitlab.com/${project}/-/issues/${issue}`;
  }
  return undefined;
}

/**
 * WaitEventLine.lines (#2599, #2747): events from one source with the same filters share a line,
 * a session said by its title and an event by its catalogue meaning.
 */
export function eventWaitSummaryLines(wait: EventWait, title: (id: string) => string | undefined): EventWaitSummaryLine[] {
  type Phrase = { finishers: true } | { words: string };
  const groups: { id: string; source: string; arguments: string[]; url: string | undefined; events: string[]; finishers: string[]; phrases: Phrase[] }[] = [];
  for (const pattern of wait.patterns) {
    const server = wait.serverEvents?.find((entry) => entry.trigger.event === pattern.name);
    const servers = server ? (server.servers.length > 0 ? server.servers : server.trigger.servers ?? []) : [];
    const source = server
      ? servers.length > 0 ? servers.map(serverName).join(" or ") : "Connected tools"
      : waitSourceName(pattern.name);
    const filterKeys = [...new Set([...Object.keys(pattern.filters), ...Object.keys(pattern.anyOf ?? {})])].sort();
    const finisherID = pattern.name === "agent.finished" && Object.keys(pattern.anyOf ?? pattern.filters).length === 1
      ? single(pattern, "agent") : undefined;
    const finisher = finisherID === undefined ? undefined : title(finisherID) ?? finisherID;
    const args = server
      ? Object.entries(server.trigger.arguments).sort(([a], [b]) => a.localeCompare(b)).map(([key, value]) => `${key} ${valueWords(value)}`)
      : finisher !== undefined ? []
      : filterKeys.map((key) => {
        const values = pattern.anyOf?.[key] ?? pattern.filters[key]!.split("|");
        return `${key} ${(key === "agent" ? values.map((id) => `“${title(id) ?? id}”`) : values).join("|")}`;
      });
    const id = `${source}\u0000${args.join("\u0000")}`;
    let group = groups.find((candidate) => candidate.id === id);
    if (!group) {
      group = { id, source, arguments: args, url: server ? triggerURL(server.trigger) : undefined, events: [], finishers: [], phrases: [] };
      groups.push(group);
    }
    if (!group.events.includes(pattern.name)) group.events.push(pattern.name);
    if (finisher !== undefined) {
      if (!group.finishers.includes(finisher)) group.finishers.push(finisher);
      if (!group.phrases.some((phrase) => "finishers" in phrase)) group.phrases.push({ finishers: true });
    } else {
      const words = server ? serverWords(pattern.name) : eventMeaning(pattern.name);
      if (!group.phrases.some((phrase) => "words" in phrase && phrase.words === words)) group.phrases.push({ words });
    }
  }
  return groups.map((group) => ({
    id: group.id,
    source: group.source,
    events: group.events,
    words: group.phrases.map((phrase, index) =>
      "finishers" in phrase ? finishing(group.finishers) : index === 0 ? phrase.words : lowered(phrase.words)).join(" or "),
    arguments: group.arguments,
    url: group.url,
  }));
}

/** WaitEventLine.lowered: "An agent…" after "or" reads "an agent…"; "PR merged" and "This Mac woke up" keep their capitals. */
function lowered(words: string): string {
  const first = words[0];
  const second = words[1];
  if (!first || first === first.toLowerCase() || words.startsWith("This Mac")) return words;
  if (second && second !== second.toLowerCase()) return words;
  return first.toLowerCase() + words.slice(1);
}

/** WaitEventLine.serverWords: a server's event by its name in words, "checks.failed" as "Checks failed", "pr.merged" as "PR merged". */
function serverWords(name: string): string {
  const words = name.split(/[._-]/).filter((word) => word.length > 0)
    .map((word) => ["pr", "mr", "ci"].includes(word.toLowerCase()) ? word.toUpperCase() : word);
  const first = words[0];
  if (first === undefined) return name;
  return [first[0]!.toUpperCase() + first.slice(1), ...words.slice(1)].join(" ");
}

function serverName(name: string): string {
  const known: Record<string, string> = { github: "GitHub", gitlab: "GitLab", linear: "Linear", email: "Email" };
  return known[name.toLowerCase()] ?? name.replace(/[-_]/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function waitSourceName(event: string): string {
  const subject = event.split(".", 1)[0] ?? "";
  if (["mac", "machine", "person", "system", "cost", "lease"].includes(subject)) return "This Mac";
  if (subject === "workflow") return "Workflows";
  if (subject === "branch") return "Branches";
  if (subject === "dropbox") return "Drop box";
  return "Agents";
}

function valueWords(value: unknown): string {
  if (typeof value === "string") return value;
  if (value === null || typeof value === "number" || typeof value === "boolean") return String(value);
  return JSON.stringify(value) ?? "null";
}

/** WaitStatus.of(…).mark for a wait on events: "◷ Waiting for “Fix login” to finish". A block's is blockLines'. */
export function eventWaitMark(agent: Agent, title: (id: string) => string | undefined,
  snapshot?: LeaseSnapshot): string | null {
  const wait = agent.eventWait;
  if (!wait || wait.ending !== undefined) return null;
  const resource = lineResource(agent);
  if (resource !== undefined) {
    const place = linePlace(agent, resource, snapshot, title);
    return `◷ Waiting for ${place ? `${place.short} \u00B7 ${ordinal(place.place)} in line` : resource}`;
  }
  const agents = wait.patterns.map((p) => {
    const id = p.name === "agent.finished" && Object.keys(p.anyOf ?? p.filters).length === 1 ? single(p, "agent") : undefined;
    return id === undefined ? undefined : title(id) ?? id;
  });
  const what = agents.length > 0 && agents.every((a) => a !== undefined)
    ? finishing(agents as string[]) : wait.patterns.map(patternLabel).join(" or ");
  return `◷ Waiting for ${what}`;
}

/** WaitStatus.things: what a wait on events waits for, one thing a pattern, an agent finishing by its name in quotes. */
export function eventWaitThings(agent: Agent, title: (id: string) => string | undefined,
  snapshot?: LeaseSnapshot): string[] {
  const wait = agent.eventWait;
  if (!wait || wait.ending !== undefined) return [];
  // A place in a line, by the resource's short name, as the lease mark had it (#2361).
  const resource = lineResource(agent);
  if (resource !== undefined) return [linePlace(agent, resource, snapshot, title)?.short ?? resource];
  return wait.patterns.map((p) => {
    const id = p.name === "agent.finished" && Object.keys(p.anyOf ?? p.filters).length === 1 ? single(p, "agent") : undefined;
    return id === undefined ? patternLabel(p) : `“${title(id) ?? id}”`;
  });
}

/** WaitStatus.rowLine: "◷ Waiting for “Fix login” (+2)", the first thing it waits for and how many more. */
export function rowWaitLine(things: string[]): string | null {
  if (things.length === 0) return null;
  return `◷ Waiting for ${things[0]}${things.length > 1 ? ` (+${things.length - 1})` : ""}`;
}

/** WaitMark: a waiting row's one line, and every line it stands for, for its title (#582). */
export interface WaitMark { line: string; detail: string }

/**
 * AgentsModel.waitMark: the agents its block waits on, what its wait on events waits for and the
 * resources it is in line for, on one line, first first; a block naming nothing says when it looks again.
 * `leases` leaves out the place in line its wait says (leaseMark's without, #2361).
 */
export function waitMark(agent: Agent, block: { names: string[]; lines: string[] }, leases: LeaseMark | null,
  title: (id: string) => string | undefined, snapshot?: LeaseSnapshot): WaitMark | null {
  const things = [...block.names, ...eventWaitThings(agent, title, snapshot), ...(leases?.waitingNames ?? [])];
  const event = eventWaitLine(agent, title, snapshot);
  const detail = [...block.lines, ...(event ? [event] : []), ...(leases?.waitingFull ?? [])];
  const line = rowWaitLine(things) ?? (detail[0] !== undefined ? `◷ ${detail[0]}` : null);
  return line === null ? null : { line, detail: detail.join("\n") };
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
