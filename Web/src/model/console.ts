// The control plane's three apps (#1804): Workspace (the sidebar and the chats), the Console (admins
// only: people, machines, requests, audit, team workflows) and Reports (everyone, scoped by role).
// One web bundle; the switcher at the top moves between them. The Mac window and the Remote draw
// the Me scope of Reports already (Cost, Time, Pool), and leave the Console to the web.
import type { SubApp } from "../route";
import type { FleetMachine, Group, PersonRow } from "../protocol/generated";
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
  { id: "reportPolicy", title: "Report Policy", about: "Who leads each group, what leads see, and each budget.", group: "Rules", built: true },
  { id: "workflows", title: "Team Workflows", about: "The bots that run the team’s workflows, and their runs.", group: "Rules", built: false },
  { id: "requests", title: "Requests", about: "Machines asking to join, and bots stopped at a cap.", group: "Records", built: false },
  { id: "audit", title: "Audit", about: "Who did what on each machine.", group: "Records", built: false },
];

/** Reports' pages. Each has three scopes: Me, a group and the organisation. */
export const reportSections: readonly Section[] = [
  { id: "spend", title: "Spend", about: "Cost, tokens and time by person, group, project, machine and runtime.", group: "Reports", built: true },
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

/** What it runs on: its workspace provider's name, or its platform ("macOS arm64"). */
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
