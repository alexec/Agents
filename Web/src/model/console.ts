// The control plane's three apps (#1804): Workspace (the sidebar and the chats), the Console (admins
// only: people, machines, requests, audit, team workflows) and Reports (everyone, scoped by role).
// One web bundle; the switcher at the top moves between them. The Mac window and the Remote draw
// the Me scope of Reports already (Cost, Time, Pool), and leave the Console to the web.
import type { SubApp } from "../route";
import type { ChannelLinkRequest, FleetMachine, Group, LiveAgent, LiveBoard, PersonRow, TeamBot } from "../protocol/generated";
import { dollars } from "./teamGroups";
import { money } from "./limits";
import { CallFailed } from "../wire/link";

export type AppName = "workspace" | SubApp;

export const apps: readonly AppName[] = ["workspace", "console", "reports"];
export const appTitle: Record<AppName, string> = { workspace: "Workspace", console: "Console", reports: "Reports" };

export interface Section {
  id: string;
  title: string;
  /** One line on what the page is for, on the Overview. */
  about: string;
  /** Under which heading of the Console's list it goes. */
  group: string;
  /** False for a page a later release builds: listed on the Overview, not opened. */
  built: boolean;
}

/** The Console's pages, in the order of its list (the concepts M1–M9 that 0.9 Team builds; #2019 has the rest). */
export const consoleSections: readonly Section[] = [
  { id: "overview", title: "Overview", about: "What the Console has, and what waits for you.", group: "Organisation", built: true },
  { id: "people", title: "People and Groups", about: "Who belongs, their roles, bots and groups.", group: "Organisation", built: true },
  { id: "machines", title: "Machines", about: "Every machine: its owner, state, version and agents.", group: "Organisation", built: true },
  { id: "projects", title: "Projects", about: "Every project: its owner and its folders on each machine. Rename and remove.", group: "Organisation", built: true },
  { id: "signIn", title: "Sign-In", about: "Your organisation’s sign-in providers, their domains and SCIM.", group: "Organisation", built: true },
  { id: "live", title: "Live Now", about: "Every agent running now, its cost so far, and Stop.", group: "Organisation", built: true },
  { id: "policy", title: "Policy", about: "The rules every machine follows: modes, sandbox, runtimes, budgets, and the kill switch.", group: "Rules", built: true },
  { id: "modelAccess", title: "Model Access", about: "The organisation’s keys and gateways to the model, and who may use each.", group: "Rules", built: true },
  { id: "reportPolicy", title: "Report Policy", about: "Who leads each group, what leads see, and each budget.", group: "Rules", built: true },
  { id: "workflows", title: "Team Workflows", about: "The bots that run the team’s workflows, and their runs.", group: "Rules", built: true },
  { id: "catalogue", title: "Catalogue", about: "Who uses each MCP server and skill, at which version, and what is approved for whom.", group: "Rules", built: true },
  { id: "requests", title: "Requests", about: "Machines asking to join, channel identities to link, bots stopped at a cap, and people asking for an MCP server or skill.", group: "Records", built: true },
  { id: "audit", title: "Audit", about: "Who did what on each machine, for one person or everyone.", group: "Records", built: true },
  { id: "readApi", title: "Read API", about: "Tokens for BI tools to read the reports, and the OTLP exporter.", group: "Records", built: true },
];

/** Reports' pages. Each has three scopes: Me, a group and the organisation. */
export const reportSections: readonly Section[] = [
  { id: "spend", title: "Spend", about: "Cost, tokens and time by person, group, folder, machine and runtime.", group: "Reports", built: true },
  { id: "outcomes", title: "Outcomes", about: "What the agents shipped: pull requests opened, merged and reverted, and the cost of each.", group: "Reports", built: true },
  { id: "time", title: "Time", about: "Where the agents’ time goes: working, or waiting for a person.", group: "Reports", built: true },
  { id: "value", title: "Value", about: "What the work cost and delivered: cost per merged pull request, per issue and per milestone, waste, and lead time.", group: "Reports", built: true },
  { id: "runtimes", title: "Runtimes", about: "Which runtime earns its cost: cost per merged pull request, and the sessions that failed.", group: "Reports", built: true },
  { id: "adoption", title: "Adoption", about: "Who uses the agents each week, and which runtimes and workflows.", group: "Reports", built: true },
  { id: "workflows", title: "Workflows", about: "Each workflow’s runs, its failed runs, and the cost of a run.", group: "Reports", built: true },
  { id: "features", title: "Features", about: "Which features the apps and agents used on your machines, the least used first.", group: "Reports", built: true },
  { id: "saved", title: "Saved Views", about: "Your saved views, each to open or copy as a digest.", group: "Saved", built: true },
];

export function sectionsOf(app: SubApp): readonly Section[] {
  return app === "console" ? consoleSections : reportSections;
}

/** The page a route opens: the one named, when it is built, or the app's first. */
export function openSection(app: SubApp, id: string | undefined): Section {
  const list = sectionsOf(app);
  return list.find((s) => s.id === id && s.built) ?? list[0]!;
}

/** The Console's groups, in order, with their pages. */
export function grouped(list: readonly Section[]): [string, Section[]][] {
  const out = new Map<string, Section[]>();
  for (const s of list) out.set(s.group, [...(out.get(s.group) ?? []), s]);
  return [...out];
}

/** The words of a call that failed, for the page. */
export function failedWords(error: unknown): string {
  if (error instanceof CallFailed) {
    return error.code === -32601 ? "This control plane does not have this page. Update it to use it." : error.message;
  }
  return "The control plane can’t be reached.";
}

export const notBuilt = "Comes in a later release.";
export const adminsOnly = "The Console is for admins. An admin of this control plane can make you one in Console ▸ People and Groups.";
export const noRoles = "This control plane keeps no roles. Update it to use the Console.";
export const consoleFoot = "The Console reads what the control plane keeps: people, machines and the numbers and events they send. It never reads a conversation.";

// Console ▸ Machines (M1): every machine, its owner, state, version and running agents.

export type FleetFilter = "all" | "offline" | "outOfDate";
export const fleetFilters: readonly FleetFilter[] = ["all", "offline", "outOfDate"];
export const fleetFilterTitle: Record<FleetFilter, string> = { all: "All", offline: "Offline", outOfDate: "Out of Date" };
export const fleetFoot = "Each machine says how many of its agents run each time it lists them. The Console counts them; it never reads what they say.";
export const noMachines = "No machines yet. A person adds one on their Mac, in Settings ▸ Machines.";

/** -1, 0 or 1 as dotted version a is older than, the same as or newer than b; 0 for one that is not a number, such as "dev". */
export function compareVersions(a: string, b: string): number {
  const parse = (v: string) => /^v?\d+(\.\d+)*$/.test(v) ? v.replace(/^v/, "").split(".").map(Number) : null;
  const x = parse(a), y = parse(b);
  if (!x || !y) return 0;
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (x[i] ?? 0) - (y[i] ?? 0);
    if (d !== 0) return Math.sign(d);
  }
  return 0;
}

/** A machine that needs an update: missing what the control plane requires, or older than it. */
export function outOfDate(m: FleetMachine, controlVersion: string | undefined): boolean {
  return m.host.state === "needsUpdate" || (m.host.missing?.length ?? 0) > 0
    || (controlVersion !== undefined && compareVersions(m.host.version, controlVersion) < 0);
}

export function fleetShown(list: readonly FleetMachine[], filter: FleetFilter, controlVersion: string | undefined): FleetMachine[] {
  switch (filter) {
    case "all": return [...list];
    case "offline": return list.filter((m) => m.host.state === "offline");
    case "outOfDate": return list.filter((m) => outOfDate(m, controlVersion));
  }
}

/** "12 machines · 10 online · 2 out of date". */
export function fleetSummary(list: readonly FleetMachine[], controlVersion: string | undefined): string {
  const online = list.filter((m) => m.host.state === "online" || m.host.state === "needsUpdate").length;
  const old = list.filter((m) => outOfDate(m, controlVersion)).length;
  const parts = [list.length === 1 ? "1 machine" : `${list.length} machines`, `${online} online`];
  if (old > 0) parts.push(`${old} out of date`);
  return parts.join(" · ");
}

/** Whose it is: "Bea", "Nightly (bot)", or "Nobody". */
export function ownerWords(m: FleetMachine): string {
  if (!m.ownerName) return "Nobody";
  return m.bot ? `${m.ownerName} (bot)` : m.ownerName;
}

/** What it runs on: its machine provider's name, or its platform ("macOS arm64"). */
export function kindWords(m: FleetMachine): string {
  return m.host.workspace?.providerName || m.host.platform || "Machine";
}

/** Its running agents, or a dash when it never listed them. */
export function runningWords(m: FleetMachine): string {
  return m.running === undefined ? "—" : String(m.running);
}

// Console ▸ Report Policy: group leads, Totals Only and budgets.

export const orgKey = "org";
export const totalsOnlyFoot = "On, a group’s leads see its spend and time added up, with no person or machine named. Off, they see each person’s. An admin always sees each person.";
export const policyFoot = "A group’s leads see its reports in Reports, beside their own. A budget is for a calendar month in US dollars, drawn with a forecast on Reports ▸ Spend.";
export const notSaved = "Not saved. Your changes stay here until you save or revert them.";

/** Who may lead a group: its people (everyone, for Everyone), never a bot. */
export function leadCandidates(group: Group, people: readonly PersonRow[]): PersonRow[] {
  return people.filter((p) => p.kind === "person" && (group.everyone || group.members.includes(p.id)));
}

/** A budget as typed: "250", "1,200.50", "$90"; null for anything else; 0 for nothing. */
export function budgetValue(text: string): number | null {
  const plain = text.trim().replace(/^\$/, "").replace(/,/g, "");
  if (plain === "") return 0;
  if (!/^\d+(\.\d{1,2})?$/.test(plain)) return null;
  return Number(plain);
}

/** A budget as the field shows it. */
export function budgetInput(usd: number): string {
  return Number.isInteger(usd) ? String(usd) : usd.toFixed(2);
}

// Console ▸ Requests (M7).

export const noRequests = "Nothing waits for you.";
export const requestsFoot = "A machine asking to join and a bot stopped at its cap are also sent to every admin’s window, Remote and page as they happen.";

/** "Sam (sam@acme.dev) on Slack wants to be linked to Sam". */
export function linkWords(r: ChannelLinkRequest): string {
  const who = r.name ? (r.email ? `${r.name} (${r.email})` : r.name) : r.identity;
  const to = r.forName ? ` to ${r.forName}` : "";
  return `${who} on ${r.channel} wants to be linked${to}`;
}

// Console ▸ Team Workflows (M6): each bot, the workflows it ran this week, and what runs now.

export const noBots = "No bots yet. Make one in People and Groups: a bot runs a workflow whose runs-on: names it.";
export const teamWorkflowsFoot = "Runs are the triggers each bot claimed in the last 7 days, once each across its machines. Stop ends one agent on a bot’s machine; the workflow runs again at its next trigger.";

/** "2 of 3 machines online". */
export function machineWords(bot: TeamBot): string {
  if (bot.machines === 0) return "No machines";
  return `${bot.online} of ${bot.machines} ${bot.machines === 1 ? "machine" : "machines"} online`;
}

/** "$4.20 today of $50 a day", "$4.20 today", or "At its cap until midnight UTC". */
export function spendWords(bot: TeamBot): string {
  if (bot.capped) return "At its cap until midnight UTC";
  const cap = bot.caps?.dailyUSD;
  return cap !== undefined ? `${dollars(bot.spentTodayUSD)} today of ${dollars(cap)} a day` : `${dollars(bot.spentTodayUSD)} today`;
}

/** "3 runs", "1 run". */
export function runsWords(runs: number): string {
  return runs === 1 ? "1 run" : `${runs} runs`;
}

// Console ▸ Live Now (#2019, M9): every agent running now on every machine, the most costly
// first, each with Stop (console/stopAgent). Ids and numbers only; no agent's title or words.

/** How many requests wait on the Console's Requests page, each kind counted (#2436: SCIM removals too). */
export function waitingCount(n: { joins: number; links: number; capped: number; governance: number; removals: number }): number {
  return n.joins + n.links + n.capped + n.governance + n.removals;
}

export const noLive = "No agent is running now on any machine.";
export const liveFoot = "The page asks each online machine for its agents every 15 seconds. A machine that is offline shows what it ran last. Stop… ends one agent, and its owner reads that an admin stopped it. For an incident, Policy’s Stop All Agent Work stops every agent on every machine.";

/** An agent's short id, its first 8 characters, so two of one runtime on one machine can be
 * told apart without its title (#2435). */
export function liveShortID(a: LiveAgent): string {
  return a.agent.slice(0, 8);
}

/** Each Stop's own name, for a screen reader (#2435). */
export function liveStopLabel(a: LiveAgent, runtime: string): string {
  return `Stop ${runtime} ${liveShortID(a)} on ${a.hostName}`;
}

/** What Stop… asks first (#2435): one click must not end the wrong agent. */
export function liveStopQuestion(a: LiveAgent, runtime: string): string {
  return `Stop ${runtime} ${liveShortID(a)} on ${a.hostName} (${a.ownerName})? It stops now, and ${a.ownerName} reads that an admin stopped it.`;
}

/** "Waiting for its person", "Waiting on others", "Starting" or "Working". */
export function liveStateWords(a: LiveAgent): string {
  if (a.state === "waitingOnUser") return "Waiting for its person";
  if (a.waitsOnOthers) return "Waiting on others";
  return a.state === "starting" ? "Starting" : "Working";
}

/** "$4.20", "$4.20 · €1.00", or "Nothing yet". */
export function liveCostWords(cost: Record<string, number> | undefined): string {
  const parts = Object.entries(cost ?? {}).filter(([, v]) => v > 0).sort(([a], [b]) => a.localeCompare(b)).map(([c, v]) => money(v, c));
  return parts.length ? parts.join(" · ") : "Nothing yet";
}

/** "3 agents on 2 machines · $7.50 so far". */
export function liveSummary(board: LiveBoard): string {
  const machines = new Set(board.agents.map((a) => a.host)).size;
  const cost: Record<string, number> = {};
  for (const a of board.agents) for (const [c, v] of Object.entries(a.costToDate ?? {})) cost[c] = (cost[c] ?? 0) + v;
  const agents = board.agents.length === 1 ? "1 agent" : `${board.agents.length} agents`;
  const on = machines === 1 ? "1 machine" : `${machines} machines`;
  const spent = liveCostWords(cost);
  return spent === "Nothing yet" ? `${agents} on ${on}` : `${agents} on ${on} · ${spent} so far`;
}

/** Each machine with agents running, the most agents first: for Stop All on a machine. */
export function liveMachines(board: LiveBoard): { host: string; hostName: string; ownerName: string; agents: LiveAgent[] }[] {
  const machines = new Map<string, { host: string; hostName: string; ownerName: string; agents: LiveAgent[] }>();
  for (const a of board.agents) {
    const m = machines.get(a.host) ?? { host: a.host, hostName: a.hostName, ownerName: a.ownerName, agents: [] };
    machines.set(a.host, m);
    m.agents.push(a);
  }
  return [...machines.values()].sort((a, b) => b.agents.length - a.agents.length || a.hostName.localeCompare(b.hostName));
}
