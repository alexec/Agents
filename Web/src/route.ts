// Where the page is, in the URL's fragment (071 research R2): #/h/<host>/p/<folder>/s/<session>, or
// /w/<workflow> for a workflow's page in the chat's place (#98), /ar/1 for the project's archive (#499),
// /rv/<kind:key> for a change waiting for an OK, on its Review page (#1472),
// or #/a/<page> for an Activity page of the sidebar (#151): events, resources, runtimes, mcp (#589),
// worktrees (#790), spending, tokens (#956) or time, or #/settings for this browser's Settings (#846).
// The Console and Reports (#1804), the control plane's other two apps beside this Workspace, are
// #/console/<section> and #/reports/<section>.
// A tab holding one project alone (#1089) starts #/o/1/…: Open in New Tab on its heading. It keeps
// to that project until ‹ All.
// Every step is a history entry, so the browser's own Back moves between columns (US6).
import { signal } from "@preact/signals";

export type ActivityPage = "events" | "resources" | "runtimes" | "mcp" | "worktrees" | "spending" | "tokens" | "time" | "milestones";

export const activityPages: readonly ActivityPage[] = ["events", "resources", "runtimes", "mcp", "worktrees", "spending", "tokens", "time", "milestones"];

/** The control plane's three apps (#1804): this Workspace, the admins' Console and Reports. */
export type SubApp = "console" | "reports";

export interface Route {
  /** The Console or Reports (#1804), in place of the sidebar and the chat. */
  app?: SubApp | undefined;
  /** The page of the Console or Reports; its first when absent. */
  section?: string | undefined;
  /** This browser's Settings (#846): which smart groups are on. */
  settings?: boolean | undefined;
  /** An Activity page (#151): about all the work rather than one project. */
  activity?: ActivityPage | undefined;
  host?: string | undefined;
  /** The project's folder URL, as the host writes it. */
  project?: string | undefined;
  session?: string | undefined;
  /** A workflow's page, in the chat's place, as the window opens one from the same list (#98). */
  workflow?: string | undefined;
  /** One of the project's pinned pages (#159), by its path in the project, in the chat's place. */
  page?: string | undefined;
  /** The files pane, open beside or over the chat. */
  files?: boolean | undefined;
  /** A new session's form, which is the project's empty pane: shown on a narrow window too. */
  compose?: boolean | undefined;
  /** The project's archived sessions and workflows (#495, #499), a page opened from one row of the sidebar. */
  archive?: boolean | undefined;
  /** The project's MCP servers and how each is doing (#753), a page opened from its row in the sidebar. */
  mcp?: boolean | undefined;
  /** A change waiting for an OK, on its Review page in the chat's place (#1472), by its approval's id. */
  review?: string | undefined;
  /** This tab holds its project alone (#1089): the sidebar is that project's only. */
  alone?: boolean | undefined;
}

/** The project this tab holds alone (#1089), from the address it was opened at; undefined for every project. */
export interface AloneProject { host: string; folder: string }

export function parseRoute(hash: string): Route {
  const path = hash.replace(/^#\/?/, "");
  if (path === "settings") return { settings: true };
  const [first, section] = path.split("/");
  if (first === "console" || first === "reports") {
    return section ? { app: first, section: decodeURIComponent(section) } : { app: first };
  }
  const parts = path.split("/").map((part) => decodeURIComponent(part));
  const route: Route = {};
  for (let i = 0; i + 1 < parts.length; i += 2) {
    const value = parts[i + 1]!;
    switch (parts[i]) {
      case "h": route.host = value; break;
      case "p": route.project = value; break;
      case "s": route.session = value; break;
      case "w": route.workflow = value; break;
      case "pg": route.page = value; break;
      case "f": route.files = value === "1"; break;
      case "n": route.compose = value === "1"; break;
      case "ar": route.archive = value === "1"; break;
      case "m": route.mcp = value === "1"; break;
      case "rv": route.review = value; break;
      case "o": route.alone = value === "1"; break;
      case "a": if ((activityPages as readonly string[]).includes(value)) route.activity = value as ActivityPage; break;
    }
  }
  return route;
}

export function routeHash(route: Route, aloneIn: AloneProject | undefined = alone.peek()): string {
  const parts: string[] = [];
  // In a tab holding one project, every place in it says so, so a reload or a copied link keeps it.
  const held = aloneIn !== undefined && route.host === aloneIn.host && route.project !== undefined
    && sameFolder(route.project, aloneIn.folder);
  if (held || (route.alone && route.host && route.project)) parts.push("o", "1");
  if (route.settings) return "#/settings";
  if (route.app) return `#/${route.app}` + (route.section ? "/" + encodeURIComponent(route.section) : "");
  if (route.activity) return "#/a/" + route.activity;
  if (route.host) parts.push("h", route.host);
  if (route.host && route.project) parts.push("p", route.project);
  if (route.host && route.project && route.review) parts.push("rv", route.review);
  else if (route.host && route.project && route.session) parts.push("s", route.session);
  else if (route.host && route.project && route.workflow) parts.push("w", route.workflow);
  else if (route.host && route.project && route.page) parts.push("pg", route.page);
  if (route.review) return "#/" + parts.map(encodeURIComponent).join("/");
  if (route.session && route.files) parts.push("f", "1");
  if (route.host && route.project && !route.session && !route.workflow && !route.page && route.compose) parts.push("n", "1");
  else if (route.host && route.project && !route.session && !route.workflow && !route.page && route.archive) parts.push("ar", "1");
  else if (route.host && route.project && !route.session && !route.workflow && !route.page && route.mcp) parts.push("m", "1");
  return "#/" + parts.map(encodeURIComponent).join("/");
}

function sameFolder(a: string, b: string): boolean {
  return a.replace(/\/+$/, "") === b.replace(/\/+$/, "");
}

/** The project the tab was opened to hold, from its address; kept until ‹ All lets it go. */
export function aloneProject(r: Route): AloneProject | undefined {
  return r.alone && r.host && r.project ? { host: r.host, folder: r.project } : undefined;
}

export const route = signal<Route>(parseRoute(globalThis.location?.hash ?? ""));
export const alone = signal<AloneProject | undefined>(aloneProject(route.peek()));
globalThis.addEventListener?.("hashchange", () => {
  route.value = parseRoute(location.hash);
  // Back to where the tab held one project, or a link to one: it holds it again.
  const held = aloneProject(route.value);
  if (held) alone.value = held;
});

/** The address of a tab holding this project alone (#1089): Open in New Tab on its heading. */
export function aloneURL(host: string, folder: string): string {
  return location.pathname + location.search + routeHash({ host, project: folder, compose: true, alone: true }, undefined);
}

/** ‹ All: the tab shows every project again, at the project it held. */
export function showAll(): void {
  const held = alone.peek();
  alone.value = undefined;
  go(held ? { host: held.host, project: held.folder } : {});
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
