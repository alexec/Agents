// Where the page is, in the URL's fragment (071 research R2): #/h/<host>/p/<folder>/s/<session>, or
// /w/<workflow> for a workflow's page in the chat's place (#98), or #/a/<page> for an Activity page
// of the sidebar (#151): events, resources, runtimes or spending.
// Every step is a history entry, so the browser's own Back moves between columns (US6).
import { signal } from "@preact/signals";

export type ActivityPage = "events" | "resources" | "runtimes" | "spending";

export const activityPages: readonly ActivityPage[] = ["events", "resources", "runtimes", "spending"];

export interface Route {
  /** An Activity page (#151): about all the work rather than one project. */
  activity?: ActivityPage | undefined;
  host?: string | undefined;
  /** The project's folder URL, as the host writes it. */
  project?: string | undefined;
  session?: string | undefined;
  /** A workflow's page, in the chat's place, as the window opens one from the same list (#98). */
  workflow?: string | undefined;
  /** The project's Dashboard (074), in the chat's place, as the window opens it from the same list. */
  dashboard?: boolean | undefined;
  /** The files pane, open beside or over the chat. */
  files?: boolean | undefined;
  /** A new session's form, which is the project's empty pane: shown on a narrow window too. */
  compose?: boolean | undefined;
}

export function parseRoute(hash: string): Route {
  const parts = hash.replace(/^#\/?/, "").split("/").map((part) => decodeURIComponent(part));
  const route: Route = {};
  for (let i = 0; i + 1 < parts.length; i += 2) {
    const value = parts[i + 1]!;
    switch (parts[i]) {
      case "h": route.host = value; break;
      case "p": route.project = value; break;
      case "s": route.session = value; break;
      case "w": route.workflow = value; break;
      case "d": route.dashboard = value === "1"; break;
      case "f": route.files = value === "1"; break;
      case "n": route.compose = value === "1"; break;
      case "a": if ((activityPages as readonly string[]).includes(value)) route.activity = value as ActivityPage; break;
    }
  }
  return route;
}

export function routeHash(route: Route): string {
  const parts: string[] = [];
  if (route.activity) return "#/a/" + route.activity;
  if (route.host) parts.push("h", route.host);
  if (route.host && route.project) parts.push("p", route.project);
  if (route.host && route.project && route.session) parts.push("s", route.session);
  else if (route.host && route.project && route.workflow) parts.push("w", route.workflow);
  else if (route.host && route.project && route.dashboard) parts.push("d", "1");
  if (route.session && route.files) parts.push("f", "1");
  if (route.host && route.project && !route.session && !route.workflow && !route.dashboard && route.compose) parts.push("n", "1");
  return "#/" + parts.map(encodeURIComponent).join("/");
}

export const route = signal<Route>(parseRoute(location.hash));
addEventListener("hashchange", () => (route.value = parseRoute(location.hash)));

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
