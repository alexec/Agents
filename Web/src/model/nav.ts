// The control plane web page by section (#2141): one bar at the top of every page, in place of
// Workspace | Console | Reports (#1804). Overview is the home; Agents is the sidebar and the chat;
// every other section is a list of pages beside the page open. A section or page only an admin can
// use is left out for a member; the control plane still checks each call's role itself.
import type { ActivityPage } from "../route";
import { reportSections, type Section } from "./console";

export type NavSection = "overview" | "agents" | "machines" | "workflows" | "reports" | "requests" | "people" | "settings";

export const navSections: readonly NavSection[] = ["overview", "agents", "machines", "workflows", "reports", "requests", "people", "settings"];

export const navTitle: Record<NavSection, string> = {
  overview: "Overview", agents: "Agents", machines: "Machines", workflows: "Workflows", reports: "Reports",
  requests: "Requests", people: "People", settings: "Settings",
};

/** The sections only an admin sees in the bar. */
const adminSections: ReadonlySet<NavSection> = new Set(["requests", "people"]);

/** How a page is drawn: an Activity page, a page of the old Console or of Reports, or one of its own. */
export type PageDraw =
  | { kind: "activity"; page: ActivityPage }
  | { kind: "console"; id: string }
  | { kind: "report"; section: Section }
  | { kind: "usage" | "lineage" | "machines" | "workflows" | "settings" };

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
  machines: [
    { id: "machines", title: "Machines", group: "Machines", draw: { kind: "machines" } },
    { id: "runtimes", title: "Runtimes", group: "On them", draw: { kind: "activity", page: "runtimes" } },
    { id: "resources", title: "Resources", group: "On them", draw: { kind: "activity", page: "resources" } },
    { id: "worktrees", title: "Worktrees", group: "On them", draw: { kind: "activity", page: "worktrees" } },
    { id: "mcp", title: "Connectors", group: "On them", draw: { kind: "activity", page: "mcp" } },
  ],
  workflows: [
    { id: "workflows", title: "Workflows", group: "Workflows", draw: { kind: "workflows" } },
    adminPage("team", "Team Workflows", "Workflows", "workflows"),
  ],
  reports: [
    ...reportSections.map((s): NavPage => ({ id: s.id, title: s.title, group: s.group, draw: { kind: "report", section: s } })),
    { id: "usage", title: "Usage", group: "Yours", draw: { kind: "usage" } },
    // The work's cost and links from any start (#3087), as the window's Cost ▸ Lineage.
    { id: "lineage", title: "Lineage", group: "Yours", draw: { kind: "lineage" } },
    { id: "milestones", title: "Milestones", group: "Yours", draw: { kind: "activity", page: "milestones" } },
    { id: "events", title: "Events", group: "Records", draw: { kind: "activity", page: "events" } },
    adminPage("audit", "Audit", "Records"),
  ],
  requests: [adminPage("requests", "Requests", "Requests")],
  people: [adminPage("people", "People and Groups", "People"), adminPage("signIn", "Sign-In", "People")],
  settings: [
    { id: "settings", title: "Settings", group: "Settings", draw: { kind: "settings" } },
    adminPage("policy", "Policy", "Organisation"),
    adminPage("modelAccess", "Model Access", "Organisation"),
    adminPage("reportPolicy", "Report Policy", "Organisation"),
    adminPage("catalogue", "Catalogue", "Organisation"),
    adminPage("readApi", "Read API", "Organisation"),
  ],
};

/** The sections in the bar: every one for an admin; for a member (or while the role is not known), not Requests or People. */
export function sectionsShown(admin: boolean | null, current: NavSection): NavSection[] {
  return navSections.filter((s) => admin === true || !adminSections.has(s) || s === current);
}

/** The pages in a section's list: every one for an admin; a member's, and the one open. */
export function pagesShown(section: NavSection, admin: boolean | null, open?: string): NavPage[] {
  return navPages[section].filter((p) => admin === true || !p.admin || p.id === open);
}

/** The page a route opens: the one named, or the section's first that this person may use. */
export function openPage(section: NavSection, id: string | undefined, admin: boolean | null): NavPage | undefined {
  const list = navPages[section];
  return list.find((p) => p.id === id) ?? list.find((p) => admin === true || !p.admin) ?? list[0];
}

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

/** Usage's three panes, which were Activity's Cost, Tokens and Time. */
export type UsagePane = "spending" | "tokens" | "time";
export const usagePanes: readonly UsagePane[] = ["spending", "tokens", "time"];
export const usagePaneTitle: Record<UsagePane, string> = { spending: "Cost", tokens: "Tokens", time: "Time" };

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
    case "runtimes": case "resources": case "worktrees": case "mcp": return { nav: "machines", section: page };
    case "events": case "milestones": return { nav: "reports", section: page };
    case "spending": case "tokens": case "time": return { nav: "reports", section: "usage", usage: page };
    default: return {};
  }
}

/** The g-then-letter key for each section. */
export const sectionKeys: Record<string, NavSection> = {
  o: "overview", a: "agents", m: "machines", w: "workflows", r: "reports", q: "requests", p: "people", s: "settings",
};
