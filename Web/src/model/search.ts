// The top bar's search (#2142): "Search or jump to…" finds, by name, the sections' pages, the machines
// and the sessions this page holds. It makes no call: what it finds is what the page already has.
import type { Route } from "../route";
import { navSections, navTitle, pagesShown, type NavSection } from "./nav";
import type { Placed } from "./overview";

export interface Found {
  kind: "page" | "machine" | "session";
  title: string;
  /** Where it is: the section, the machine's platform, the session's folder and machine. */
  detail: string;
  to: Route;
}

/** The most results the list shows. */
export const foundLimit = 8;

function score(name: string, words: string): number {
  const n = name.toLowerCase();
  if (n === words) return 0;
  if (n.startsWith(words)) return 1;
  if (n.split(/[\s\-_/·]+/).some((w) => w.startsWith(words))) return 2;
  return n.includes(words) ? 3 : -1;
}

/** What the words find, the best first: a name the same, then starting with them, then a word starting with them,
 *  then holding them; pages before machines before sessions where they tie. Nothing for no words. */
export function searchFound(query: string, admin: boolean | null, machines: readonly { id: string; name: string; platform?: string }[],
  sessions: readonly Placed[]): Found[] {
  const words = query.trim().toLowerCase();
  if (!words) return [];
  const found: { f: Found; s: number; k: number }[] = [];
  const add = (f: Found, name: string, k: number) => {
    const s = score(name, words);
    if (s >= 0) found.push({ f, s, k });
  };
  for (const section of navSections) {
    if (section === "overview") add({ kind: "page", title: navTitle.overview, detail: "Section", to: {} }, navTitle.overview, 0);
    if (section === "overview" || (!admin && (section === "requests" || section === "people"))) continue;
    const pages = pagesShown(section, admin);
    // A section's own name opens its first page; a page of the same name as its section is not listed twice.
    add({ kind: "page", title: navTitle[section], detail: "Section", to: { nav: section as Exclude<NavSection, "overview"> } }, navTitle[section], 0);
    for (const p of pages) {
      if (p.title === navTitle[section]) continue;
      add({ kind: "page", title: p.title, detail: navTitle[section], to: { nav: section as Exclude<NavSection, "overview">, section: p.id } }, p.title, 0);
    }
  }
  for (const m of machines) add({ kind: "machine", title: m.name, detail: m.platform ? `Machine · ${m.platform}` : "Machine", to: { nav: "machines" } }, m.name, 1);
  for (const { host, folder, agent } of sessions) {
    const title = agent.title?.trim() || "New session";
    add({ kind: "session", title, detail: `${folder.name} · ${host.name}`, to: { host: host.id, folder: folder.folder.folder, session: agent.id } }, title, 2);
  }
  return found.sort((a, b) => a.s - b.s || a.k - b.k || a.f.title.localeCompare(b.f.title)).slice(0, foundLimit).map((x) => x.f);
}

