// The control plane web page by section (#2141): one bar at the top of every page, in place of
// Workspace | Console | Reports (#1804). Overview is the home; Agents is the sidebar and the chat;
// every other section is a list of pages beside the page open. A section or page only an admin can
// use is left out for a member; the control plane still checks each call's role itself.
import type { ActivityPage } from "../route";
import { reportSections, type Section } from "./console";
import { workKinds, workKindTitle, type WorkKind } from "./work";

export type NavSection = "overview" | "agents" | "work" | "docs" | "messages" | "machines" | "workflows" | "reports" | "requests" | "people" | "status" | "settings";

export const navSections: readonly NavSection[] = ["overview", "agents", "work", "docs", "messages", "machines", "workflows", "reports", "requests", "people", "status", "settings"];

export const navTitle: Record<NavSection, string> = {
  overview: "Overview", agents: "Agents", work: "Work", docs: "Docs", messages: "Messages", machines: "Machines", workflows: "Workflows", reports: "Reports",
  requests: "Requests", people: "People", status: "Status", settings: "Settings",
};

/** The sections only an admin sees in the bar. */
const adminSections: ReadonlySet<NavSection> = new Set(["requests", "people"]);

/** How a page is drawn: an Activity page, a page of the old Console or of Reports, or one of its own. */
export type PageDraw =
  | { kind: "activity"; page: ActivityPage }
  | { kind: "console"; id: string }
  | { kind: "report"; section: Section }
  | { kind: "work"; work: WorkKind }
  | { kind: "features" }
  | { kind: "timeline" }
  | { kind: "docs" }
  | { kind: "messages" }
  | { kind: "machine"; host: string }
  | { kind: "secrets" }
  | { kind: "accounts" }
  | { kind: "statusList"; list: "secrets" | "accounts" }
  | { kind: "multiplier" }
  | { kind: "usage" | "machines" | "workflows" | "settings" };

export interface NavPage {
  id: string;
  title: string;
  /** Under which heading of the section's list it goes. */
  group: string;
  /** Only an admin sees it in the list; a member who opens it by its address is told why. */
  admin?: boolean;
  draw: PageDraw;
}

const adminPage = (id: string, title: string, group: string, consoleID = id): NavPage =>
  ({ id, title, group, admin: true, draw: { kind: "console", id: consoleID } });

/** Each section's pages, in the order of its list. Overview has none; Agents' are rows at the sidebar's foot. */
export const navPages: Record<NavSection, readonly NavPage[]> = {
  overview: [],
  agents: [
    adminPage("live", "Live Now", "Agents"),
    { id: "projects", title: "Projects", group: "Agents", draw: { kind: "console", id: "projects" } },
  ],
  // Every issue and pull request from the forges, with lineage on top, and the releases lineage knows
  // (#3119). The page's id is the lineage kind, so #/work/pr/<ref> is a PR's page.
  // Features (#3269) after Pull requests: the feature:<name> labels on the epics, not a lineage kind.
  // Timeline (#4206) after Releases: the epics in time, from work/timeline.
  work: workKinds.flatMap((k): NavPage[] => [
    { id: k, title: workKindTitle[k], group: "Work", draw: { kind: "work", work: k } },
    ...k === "pr" ? [{ id: "features", title: "Features", group: "Work", draw: { kind: "features" } } satisfies NavPage] : [],
    ...k === "release" ? [{ id: "timeline", title: "Timeline", group: "Work", draw: { kind: "timeline" } } satisfies NavPage] : [],
  ]),
  // The folders' docs and the docs connectors' (#3321, spec 3319), one page; #/docs/<ref> is a doc's page.
  docs: [{ id: "docs", title: "Docs", group: "Docs", draw: { kind: "docs" } }],
  // The messaging connectors' conversations (#4344), with a reply (#4345), one page; #/messages/<key> is a conversation's.
  messages: [{ id: "messages", title: "Messages", group: "Messages", draw: { kind: "messages" } }],
  machines: [
    { id: "machines", title: "Machines", group: "Machines", draw: { kind: "machines" } },
  ],
  workflows: [
    { id: "workflows", title: "Workflows", group: "Workflows", draw: { kind: "workflows" } },
    adminPage("team", "Team Workflows", "Workflows", "workflows"),
  ],
  reports: [
    ...reportSections.map((s): NavPage => ({ id: s.id, title: s.title, group: s.group, draw: { kind: "report", section: s } })),
    // The Multiplier page first (#3990), as the window's first row under Usage; it took the Achievements page's place.
    { id: "multiplier", title: "Multiplier", group: "Yours", draw: { kind: "multiplier" } },
    { id: "usage", title: "Usage", group: "Yours", draw: { kind: "usage" } },
    adminPage("audit", "Audit", "Records"),
  ],
  requests: [adminPage("requests", "Requests", "Requests")],
  people: [adminPage("people", "People and Groups", "People"), adminPage("signIn", "Sign-In", "People")],
  // Status (#3998), status only and no settings, as the window's sidebar group: each runtime once, with the accounts, and a
  // line per machine (#3631), and the record of what happened (was Reports ▸ Records ▸ Events).
  status: [
    { id: "runtimes", title: "Runtimes", group: "Status", draw: { kind: "activity", page: "runtimes" } },
    { id: "events", title: "Events", group: "Status", draw: { kind: "activity", page: "events" } },
    // What happened last to the person's secrets and accounts (#4161): read only, a press opens Settings ▸ You.
    { id: "secrets", title: "Secrets", group: "Status", draw: { kind: "statusList", list: "secrets" } },
    { id: "accounts", title: "Accounts", group: "Status", draw: { kind: "statusList", list: "accounts" } },
  ],
  // You first (#3998), as the window's Settings rail: the person's own connectors, their secrets and cards, which go to every
  // machine of theirs (#3632), and their outside accounts (#3967), kept and sent as their secrets are. Was Your setup.
  // Settings itself is still the page the section opens on (settingsHome).
  settings: [
    { id: "mcp", title: "Connectors", group: "You", draw: { kind: "activity", page: "mcp" } },
    { id: "secrets", title: "Secrets", group: "You", draw: { kind: "secrets" } },
    { id: "accounts", title: "Accounts", group: "You", draw: { kind: "accounts" } },
    { id: "settings", title: "Settings", group: "Settings", draw: { kind: "settings" } },
    adminPage("policy", "Policy", "Organisation"),
    adminPage("modelAccess", "Model Access", "Organisation"),
    adminPage("reportPolicy", "Report Policy", "Organisation"),
    adminPage("catalogue", "Catalogue", "Organisation"),
    adminPage("readApi", "Read API", "Organisation"),
  ],
};

/** A page per machine (#3626), after Machines ▸ Machines: its CPU, memory, disks, worktrees (#3627), runtimes and resources (#3629). The Mac first, then the
 * others by name. */
export function machinePages(hosts: readonly { id: string; name: string }[], macID: string): NavPage[] {
  const sorted = [...hosts].sort((a, b) => Number(b.id === macID) - Number(a.id === macID) || a.name.localeCompare(b.name));
  return sorted.map((h) => ({ id: `machine-${h.id}`, title: h.name, group: "Machines", draw: { kind: "machine", host: h.id } }));
}

/** A section's pages with the ones made from data put in: the machines' after Machines ▸ Machines. */
export function withPages(section: NavSection, more: readonly NavPage[]): readonly NavPage[] {
  if (section !== "machines" || more.length === 0) return navPages[section];
  const list = navPages[section];
  return [...list.slice(0, 1), ...more, ...list.slice(1)];
}

/** The sections in the bar: every one for an admin; for a member (or while the role is not known), not Requests or People. */
export function sectionsShown(admin: boolean | null, current: NavSection): NavSection[] {
  return navSections.filter((s) => admin === true || !adminSections.has(s) || s === current);
}

/** The pages in a section's list: every one for an admin; a member's, and the one open. */
export function pagesShown(section: NavSection, admin: boolean | null, open?: string, more: readonly NavPage[] = []): NavPage[] {
  return withPages(section, more).filter((p) => admin === true || !p.admin || p.id === open);
}

/** The page a route opens: the one named, or the section's first that this person may use. */
export function openPage(section: NavSection, id: string | undefined, admin: boolean | null,
                         more: readonly NavPage[] = []): NavPage | undefined {
  const list = withPages(section, more);
  return list.find((p) => p.id === id) ?? list.find((p) => p.id === sectionHome[section])
    ?? list.find((p) => admin === true || !p.admin) ?? list[0];
}

/** The page a section opens on when it is not its first: Settings, below the You group (#3998). */
const sectionHome: Partial<Record<NavSection, string>> = { settings: "settings" };

/** Whether a page is for admins only and this person is not one (or not known yet). */
export function gated(page: NavPage, admin: boolean | null): boolean {
  return page.admin === true && admin !== true;
}

/** The page groups of a section's list, in order. */
export function groupedPages(list: readonly NavPage[]): [string, NavPage[]][] {
  const out = new Map<string, NavPage[]>();
  for (const p of list) out.set(p.group, [...(out.get(p.group) ?? []), p]);
  return [...out];
}

/** Usage's panes: Activity's Cost, Tokens and Time, then Velocity, the PRs that landed (#4598). */
export type UsagePane = "spending" | "tokens" | "time" | "velocity";
export const usagePanes: readonly UsagePane[] = ["spending", "tokens", "time", "velocity"];
export const usagePaneTitle: Record<UsagePane, string> = { spending: "Cost", tokens: "Tokens", time: "Time", velocity: "Velocity" };

/** Where an address from before #2141 goes now: `#/console/<page>` and `#/a/<page>`. */
export function movedPage(app: "console" | "a", page: string | undefined): { nav?: NavSection; section?: string; usage?: UsagePane } {
  if (app === "console") {
    switch (page) {
      case undefined: case "overview": return {};
      case "live": case "projects": return { nav: "agents", section: page };
      case "machines": return { nav: "machines", section: "machines" };
      case "workflows": return { nav: "workflows", section: "team" };
      case "audit": return { nav: "reports", section: "audit" };
      case "requests": return { nav: "requests" };
      case "people": case "signIn": return { nav: "people", section: page };
      case "policy": case "modelAccess": case "reportPolicy": case "catalogue": case "readApi": return { nav: "settings", section: page };
      default: return {};
    }
  }
  switch (page) {
    // Runtimes went to Status and Connectors to Settings ▸ You (#3998).
    case "runtimes": return { nav: "status", section: page };
    case "mcp": return { nav: "settings", section: page };
    // Worktrees (#3627) and resources (#3629) are on each machine's page now.
    case "worktrees": case "resources": return { nav: "machines", section: "machines" };
    case "events": return { nav: "status", section: page };
    case "achievements": return { nav: "reports", section: "multiplier" };
    case "spending": case "tokens": case "time": case "velocity": return { nav: "reports", section: "usage", usage: page };
    default: return {};
  }
}

/** The g-then-letter key for each section. */
export const sectionKeys: Record<string, NavSection> = {
  o: "overview", a: "agents", i: "work", d: "docs", m: "machines", w: "workflows", r: "reports", q: "requests", p: "people", t: "status", s: "settings",
};
