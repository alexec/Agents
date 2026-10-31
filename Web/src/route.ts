// Where the page is, in the URL's fragment (071 research R2): #/h/<host>/p/<folder>/s/<session>, or
// /w/<workflow> for a workflow's page in the chat's place (#98), /ar/1 for the folder's archive (#499),
// /rv/<kind:key> for a change waiting for an OK, on its Review page (#1472),
// The page is by section (#2141): #/ is the Overview, #/agents the sidebar with nothing chosen, and
// #/<section>/<page> a page of another section (#/machines/runtimes, #/reports/spend, #/settings/policy).
// The addresses before it, #/console/<page> (#1804) and #/a/<page> (#151), are read as their new place.
// A tab holding one folder alone (#1089) starts #/o/1/…: Open in New Tab on its heading. It keeps
// to that folder until ‹ All.
// Every step is a history entry, so the browser's own Back moves between columns (US6).
import { signal } from "@preact/signals";
import { movedPage, navSections, type NavSection, type UsagePane } from "./model/nav";

export type ActivityPage = "events" | "resources" | "runtimes" | "mcp" | "worktrees" | "spending" | "tokens" | "time" | "milestones";

export interface Route {
  /** The section (#2141); none is the Overview, or Agents when a host is named. */
  nav?: Exclude<NavSection, "overview"> | undefined;
  /** The page of the section; its first when absent. In Agents, Live Now or Projects in the chat's place. */
  section?: string | undefined;
  host?: string | undefined;
  /** The folder URL, as the host writes it. */
  folder?: string | undefined;
  session?: string | undefined;
  /** A workflow's page, in the chat's place, as the window opens one from the same list (#98). */
  workflow?: string | undefined;
  /** One of the folder's pinned pages (#159), by its path in the folder, in the chat's place. */
  page?: string | undefined;
  /** The files pane, open beside or over the chat. */
  files?: boolean | undefined;
  /** A new session's form, which is the folder's empty pane: shown on a narrow window too. */
  compose?: boolean | undefined;
  /** The folder's archived sessions and workflows (#495, #499), a page opened from one row of the sidebar. */
  archive?: boolean | undefined;
  /** The folder's MCP servers and how each is doing (#753), a page opened from its row in the sidebar. */
  mcp?: boolean | undefined;
  /** A change waiting for an OK, on its Review page in the chat's place (#1472), by its approval's id. */
  review?: string | undefined;
  /** This tab holds its folder alone (#1089): the sidebar is that folder's only. */
  alone?: boolean | undefined;
}

/** The folder this tab holds alone (#1089), from the address it was opened at; undefined for every folder. */
export interface AloneFolder { host: string; folder: string }

/** Usage's pane, when an old address (#/a/tokens) named one. */
export const usageAsked = signal<UsagePane | undefined>(undefined);

export function parseRoute(hash: string): Route {
  const path = hash.replace(/^#\/?/, "");
  const [first, section] = path.split("/");
  if (first === "console" || first === "a") {
    const moved = movedPage(first, section === undefined ? undefined : decodeURIComponent(section));
    if (moved.usage) usageAsked.value = moved.usage;
    const r: Route = {};
    if (moved.nav && moved.nav !== "overview") r.nav = moved.nav;
    if (moved.section) r.section = moved.section;
    return r;
  }
  if (first && first !== "overview" && (navSections as readonly string[]).includes(first)) {
    const nav = first as Exclude<NavSection, "overview">;
    return section ? { nav, section: decodeURIComponent(section) } : { nav };
  }
  const parts = path.split("/").map((part) => decodeURIComponent(part));
  const route: Route = {};
  for (let i = 0; i + 1 < parts.length; i += 2) {
    const value = parts[i + 1]!;
    switch (parts[i]) {
      case "h": route.host = value; break;
      case "p": route.folder = value; break;
      case "s": route.session = value; break;
      case "w": route.workflow = value; break;
      case "pg": route.page = value; break;
      case "f": route.files = value === "1"; break;
      case "n": route.compose = value === "1"; break;
      case "ar": route.archive = value === "1"; break;
      case "m": route.mcp = value === "1"; break;
      case "rv": route.review = value; break;
      case "o": route.alone = value === "1"; break;
    }
  }
  return route;
}

export function routeHash(route: Route, aloneIn: AloneFolder | undefined = alone.peek()): string {
  const parts: string[] = [];
  // In a tab holding one folder, every place in it says so, so a reload or a copied link keeps it.
  const held = aloneIn !== undefined && route.host === aloneIn.host && route.folder !== undefined
    && sameFolder(route.folder, aloneIn.folder);
  if (held || (route.alone && route.host && route.folder)) parts.push("o", "1");
  if (route.nav && !(route.nav === "agents" && route.host)) return sectionHash(route);
  if (route.host) parts.push("h", route.host);
  if (route.host && route.folder) parts.push("p", route.folder);
  if (route.host && route.folder && route.review) parts.push("rv", route.review);
  else if (route.host && route.folder && route.session) parts.push("s", route.session);
  else if (route.host && route.folder && route.workflow) parts.push("w", route.workflow);
  else if (route.host && route.folder && route.page) parts.push("pg", route.page);
  if (route.review) return "#/" + parts.map(encodeURIComponent).join("/");
  if (route.session && route.files) parts.push("f", "1");
  if (route.host && route.folder && !route.session && !route.workflow && !route.page && route.compose) parts.push("n", "1");
  else if (route.host && route.folder && !route.session && !route.workflow && !route.page && route.archive) parts.push("ar", "1");
  else if (route.host && route.folder && !route.session && !route.workflow && !route.page && route.mcp) parts.push("m", "1");
  return "#/" + parts.map(encodeURIComponent).join("/");
}

function sameFolder(a: string, b: string): boolean {
  return a.replace(/\/+$/, "") === b.replace(/\/+$/, "");
}

/** The folder the tab was opened to hold, from its address; kept until ‹ All lets it go. */
export function aloneFolder(r: Route): AloneFolder | undefined {
  return r.alone && r.host && r.folder ? { host: r.host, folder: r.folder } : undefined;
}

/** A section's page's address: #/reports/spend; #/ for the Overview. */
function sectionHash(r: Route): string {
  return r.nav ? `#/${r.nav}` + (r.section ? "/" + encodeURIComponent(r.section) : "") : "#/";
}

/** Whether an address is one from before #2141, which the page writes again as its new place. */
export function isOldAddress(hash: string): boolean {
  return /^#\/?(console|a)(\/|$)/.test(hash);
}

/** The section a route is in: Agents for a host's places, the Overview for none. */
export function sectionOf(r: Route): NavSection {
  return r.nav ?? (r.host ? "agents" : "overview");
}

/** An old address is replaced by its new one, so Back never goes to it. */
function settle(): void {
  const hash = globalThis.location?.hash ?? "";
  if (isOldAddress(hash)) history.replaceState(null, "", sectionHash(parseRoute(hash)));
}
settle();

export const route = signal<Route>(parseRoute(globalThis.location?.hash ?? ""));
export const alone = signal<AloneFolder | undefined>(aloneFolder(route.peek()));
globalThis.addEventListener?.("hashchange", () => {
  settle();
  route.value = parseRoute(location.hash);
  // Back to where the tab held one folder, or a link to one: it holds it again.
  const held = aloneFolder(route.value);
  if (held) alone.value = held;
});

/** The address of a tab holding this folder alone (#1089): Open in New Tab on its heading. */
export function aloneURL(host: string, folder: string): string {
  return location.pathname + location.search + routeHash({ host, folder: folder, compose: true, alone: true }, undefined);
}

/** ‹ All: the tab shows every folder again, at the folder it held. */
export function showAll(): void {
  const held = alone.peek();
  alone.value = undefined;
  go(held ? { host: held.host, folder: held.folder } : {});
}

/** Goes to `next` as a new history entry. */
export function go(next: Route): void {
  const hash = routeHash(next);
  if (hash !== location.hash) location.hash = hash;
}

/** Changes the route in place: opening or closing the files pane is not a step Back undoes. */
export function replace(next: Route): void {
  const hash = routeHash(next);
  if (hash === location.hash) return;
  history.replaceState(null, "", hash);
  route.value = parseRoute(hash);
}
