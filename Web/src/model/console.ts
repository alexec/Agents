// The control plane's three apps (#1804): Workspace (the sidebar and the chats), the Console (admins
// only: people, machines, requests, audit, team workflows) and Reports (everyone, scoped by role).
// One web bundle; the switcher at the top moves between them. The Mac window and the Remote draw
// the Me scope of Reports already (Cost, Time, Pool), and leave the Console to the web.
import type { SubApp } from "../route";

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
  { id: "people", title: "People and Groups", about: "Who belongs, their roles, bots and groups.", group: "Organisation", built: false },
  { id: "machines", title: "Machines", about: "Every machine: its owner, state, version and agents.", group: "Organisation", built: false },
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

export const notBuilt = "Comes in a later release.";
export const adminsOnly = "The Console is for admins. An admin of this control plane can make you one in Settings ▸ People.";
export const noRoles = "This control plane keeps no roles. Update it to use the Console.";
export const consoleFoot = "The Console reads what the control plane keeps: people, machines and the numbers and events they send. It never reads a conversation.";
