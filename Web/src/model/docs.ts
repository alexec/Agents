// Docs (#3321, spec 3319): every machine's docs (docs/list), grouped by source, a folder's by its
// subfolders; search (docs/search) with each match's line and snippet; and a doc's page (docs/read).
// As the window's DocsModel: the same groups, words and refs.
import type { Doc, DocsSearchResult, DocsSource } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { maximumLabelLength } from "./labels";

export type DocsSort = "updated" | "title";
export const docsSortTitle: Record<DocsSort, string> = { updated: "Last updated", title: "Title" };

/** One machine's docs/list, or why it could not be read. */
export interface HostDocs {
  host: string;
  /** The machine's name, said beside a folder when there are several machines. */
  name: string;
  docs: Doc[];
  sources: DocsSource[];
  problem?: string | undefined;
}

/** A source as the list shows it: one per folder of each machine, one per connector of them all. */
export interface DocsSourceRow {
  /** host|id for a folder; the id alone for a connector, which is one source on every machine. */
  key: string;
  host: string;
  source: DocsSource;
  heading: string;
}

/** The docs of one subfolder of a source: "specs/", "docs/", or "" for its top. */
export interface DocsShelf {
  dir: string;
  docs: Doc[];
}

export interface DocsGroup extends DocsSourceRow {
  shelves: DocsShelf[];
}

/** The key the list keeps a source by: one connector on two machines is one source, the first kept. */
export function sourceKey(host: string, source: Pick<DocsSource, "id" | "kind">): string {
  return source.kind === "connector" ? source.id : `${host}|${source.id}`;
}

/** Every machine's sources, the folders first and then the connectors, each once. */
export function mergeSources(lists: readonly HostDocs[]): DocsSourceRow[] {
  const several = lists.length > 1;
  const seen = new Set<string>();
  const out: DocsSourceRow[] = [];
  for (const kind of ["folder", "connector"] as const) {
    for (const l of lists) {
      for (const s of l.sources) {
        if (s.kind !== kind) continue;
        const key = sourceKey(l.host, s);
        if (seen.has(key)) continue;
        seen.add(key);
        out.push({ key, host: l.host, source: s, heading: kind === "folder" && several ? `${s.name} (${l.name})` : s.name });
      }
    }
  }
  return out;
}

/** The sources and their docs, sorted, with the one source asked for or all of them. */
export function docsGroups(lists: readonly HostDocs[], sort: DocsSort, only = ""): DocsGroup[] {
  const sources = mergeSources(lists).filter((s) => !only || s.key === only);
  return sources.map((s) => {
    const docs = lists.filter((l) => s.source.kind === "connector" || l.host === s.host)
      .flatMap((l) => l.docs.filter((d) => d.source === s.source.id));
    return { ...s, shelves: shelves(unique(docs), sort, s.source.kind === "folder") };
  });
}

function unique(docs: readonly Doc[]): Doc[] {
  const seen = new Set<string>();
  return docs.filter((d) => !seen.has(d.ref) && seen.add(d.ref));
}

/** A folder's docs by their first folder (specs/, docs/), those at its top last; a connector's in one. */
export function shelves(docs: readonly Doc[], sort: DocsSort, byFolder: boolean): DocsShelf[] {
  const by = new Map<string, Doc[]>();
  for (const d of docs) {
    const dir = byFolder ? dirOf(d.path ?? "") : "";
    by.set(dir, [...by.get(dir) ?? [], d]);
  }
  return [...by].sort(([a], [b]) => (a === "" ? 1 : b === "" ? -1 : a.localeCompare(b)))
    .map(([dir, list]) => ({ dir, docs: sortDocs(list, sort) }));
}

/** "specs/" for specs/3319-docs/spec.md; "" for README.md. */
export function dirOf(path: string): string {
  const i = path.indexOf("/");
  return i < 0 ? "" : path.slice(0, i + 1);
}

/** The path under its shelf: 3319-docs/spec.md on the specs/ shelf. */
export function underShelf(doc: Doc, dir: string): string {
  const name = shortForm(doc);
  return dir && name.startsWith(dir) ? name.slice(dir.length) : name;
}

export function sortDocs(docs: readonly Doc[], sort: DocsSort): Doc[] {
  return [...docs].sort((a, b) => {
    if (sort === "updated") {
      const d = (b.updated ?? -Infinity) - (a.updated ?? -Infinity);
      if (d !== 0 && !Number.isNaN(d)) return d;
    }
    return a.title.localeCompare(b.title, undefined, { sensitivity: "base" });
  });
}

/** What a row and a page title say: the path of a folder doc, the title of a connector doc. */
export function shortForm(doc: Pick<Doc, "path" | "title">): string {
  return doc.path || doc.title;
}

/** The title beside a folder doc's path, when it says more than the file name. */
export function titleBeside(doc: Doc): string | undefined {
  if (!doc.path) return undefined;
  const file = doc.path.split("/").pop() ?? "";
  return doc.title && doc.title !== file ? doc.title : undefined;
}

export function updatedWords(doc: Pick<Doc, "updated">, now: Date = new Date()): string {
  if (doc.updated === undefined) return "";
  const seconds = Math.max(0, (now.getTime() - fromWireDate(doc.updated).getTime()) / 1000);
  if (seconds < 60) return "just now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)}h ago`;
  if (seconds < 7 * 86_400) return `${Math.floor(seconds / 86_400)}d ago`;
  if (seconds < 365 * 86_400) return `${Math.floor(seconds / (7 * 86_400))}w ago`;
  return `${Math.floor(seconds / (365 * 86_400))}y ago`;
}

/** Whether a doc is a folder's own file, which its page follows as it changes. */
export function isFolderDoc(doc: Pick<Doc, "source" | "path">): boolean {
  return !!doc.path && !doc.source.startsWith("mcp:");
}

/** The vendor a connector doc opens in, by its ref's scheme; a mapped server by its name. */
export function vendorName(ref: string): string {
  const scheme = ref.slice(0, ref.indexOf(":"));
  switch (scheme) {
    case "confluence": return "Confluence";
    case "notion": return "Notion";
    case "gdrive": return "Google Drive";
    case "mcp": return ref.slice(4).split("/")[0] || "its app";
    default: return "its app";
  }
}

/** What a source that did not answer says in place of its docs. */
export function sourceProblem(source: DocsSource): string | undefined {
  if (source.state === "notMapped") return "not mapped";
  if (source.state === "failed") return source.message ? `could not be read: ${source.message}` : "could not be read";
  return undefined;
}

/** The prompt Map it… starts a session with, in the folder whose Docs slot holds the connector. */
export function mapItPrompt(source: DocsSource): string {
  return `Map the docs server ${source.name} with the map-a-docs-server skill, so Docs can list and read it.`;
}

/** Every machine's search results, the most matches first, each doc once. */
export function mergeResults(lists: readonly { host: string; results: DocsSearchResult[] }[]): (DocsSearchResult & { host: string })[] {
  const seen = new Set<string>();
  const out: (DocsSearchResult & { host: string })[] = [];
  for (const l of lists) {
    for (const r of l.results) {
      if (seen.has(r.doc.ref)) continue;
      seen.add(r.doc.ref);
      out.push({ ...r, host: l.host });
    }
  }
  return out.sort((a, b) => b.matches.length - a.matches.length);
}

/** The Mac window's address of a doc (spec 3319). */
export function windowAddress(ref: string): string {
  return `agents://docs/${ref}`;
}

// Start Agent on a doc's page, and the Docs section on Work's issue and PR pages (#3322), as the
// window's DocsStart: the three starts and their prompts, the doc: label, the docs an item's body
// names, and the words its title is searched by.

/** The three ways Start Agent ▾ starts a session from a doc. */
export type DocStart = "build" | "review" | "ask";
export const docStarts: readonly DocStart[] = ["build", "review", "ask"];
export const docStartTitle: Record<DocStart, string> = { build: "Build this", review: "Review this", ask: "Ask about this" };
export const docStartHelp: Record<DocStart, string> = {
  build: "A new session that builds what this doc describes",
  review: "A new session that finds what is missing or wrong in this doc, and files it",
  ask: "A new session that answers a question about this doc",
};

/** The prompt the new-session form opens with. The doc's ref names it, and the session reads it with
 * docs_read. Ask about this ends where the person types the question. */
export function docStartPrompt(start: DocStart, ref: string): string {
  switch (start) {
    case "build": return `Build what the doc ${ref} describes. Read it with the docs_read tool first.`;
    case "review": return `Review the doc ${ref}. Read it with the docs_read tool, find what is missing or wrong in it, and file each thing you find as an issue.`;
    case "ask": return `Read the doc ${ref} with the docs_read tool, then answer: `;
  }
}

/** Build this names the doc the session works from (doc:<short form>), as #<n> names an issue. */
export function docStartLabels(start: DocStart, doc: Pick<Doc, "path" | "title">): string[] {
  return start === "build" ? [docLabel(doc)] : [];
}

/** doc:<short form>, cut to a session label's length (24): a path keeps its last whole parts
 * (doc:3319-docs/spec.md), a file name too long keeps its end, a title its start. */
export function docLabel(doc: Pick<Doc, "path" | "title">): string {
  const room = maximumLabelLength - "doc:".length;
  const short = [...shortForm(doc)];
  if (short.length <= room) return `doc:${short.join("")}`;
  if (!doc.path) return `doc:${short.slice(0, room).join("")}`;
  let kept = "";
  for (const part of short.join("").split("/").filter(Boolean).reverse()) {
    const next = kept ? `${part}/${kept}` : part;
    if ([...next].length > room) break;
    kept = next;
  }
  return `doc:${kept || short.slice(-room).join("")}`;
}

/** The most docs an item's Docs section shows from its body, and from a search for its title. */
export const linkedMost = 10;
export const relatedMost = 3;

/** github:alexec/agents/doc/ for github:alexec/agents#12; undefined for an item of no repo. */
export function repoPrefix(itemRef: string): string | undefined {
  const m = /^([a-z]+:[^\s#!]+\/[^\s#!]+)[#!][0-9]+$/.exec(itemRef);
  return m ? `${m[1]!.toLowerCase()}/doc/` : undefined;
}

/** The docs an issue's or a PR's body names, in its order, each once: a doc's ref, its address
 * (#/docs/<ref>, agents://docs/<ref>), and a specs/ or docs/ Markdown path, which is a doc of the
 * item's own repo. */
export function linkedRefs(body: string, itemRef: string): string[] {
  const found: { at: number; ref: string }[] = [];
  // #/docs/<ref> (the web page's, its ref encoded) or agents://docs/<ref> (the Mac window's).
  for (const m of body.matchAll(/(?:#\/docs\/|agents:\/\/docs\/)([^\s)\]>`'"]+)/g)) {
    let ref = m[1]!;
    try { ref = decodeURIComponent(ref); } catch { /* kept as written */ }
    found.push({ at: m.index, ref });
  }
  // A folder doc's ref (<scheme>:<repo or machine/folder>/doc/<path>), or a connector doc's; one
  // inside an address is found once, as the address.
  for (const m of body.matchAll(/\b(?:[a-z]+:[^\s/:]+(?:\/[^\s/]+)+\/doc\/[^\s)\]>`'"]+|(?:confluence|notion|gdrive|mcp):[^\s)\]>`'"]+)/g)) {
    if (m.index > 0 && body[m.index - 1] === "/") continue;
    found.push({ at: m.index, ref: m[0] });
  }
  const repo = repoPrefix(itemRef);
  // A Markdown path under specs/ or docs/, not inside a longer path or a URL.
  if (repo) {
    for (const m of body.matchAll(/(?:^|[^\w/.:-])((?:specs|docs)\/[\w./-]+\.md)\b/g)) {
      found.push({ at: m.index + m[0].length - m[1]!.length, ref: repo + m[1]! });
    }
  }
  const seen = new Set<string>();
  return found.sort((a, b) => a.at - b.at)
    .map((f) => f.ref.replace(/[.,;:!?]+$/, ""))
    .filter((r) => r && !seen.has(r) && seen.add(r))
    .slice(0, linkedMost);
}

const commonWords = new Set([
  "about", "after", "also", "and", "from", "have", "into", "make", "more", "only", "page", "pages", "that",
  "their", "them", "then", "there", "this", "what", "when", "where", "which", "with", "without", "work",
]);

/** The words an item's title is searched by: its own words of four letters or more, not the common
 * ones, the longest first. Each is searched alone, since docs/search wants every word on one line. */
export function searchWords(title: string, most = 4): string[] {
  const seen = new Set<string>();
  const words = title.toLowerCase().split(/[^\p{L}\p{N}]+/u)
    .filter((w) => [...w].length >= 4 && !/^\p{N}+$/u.test(w) && !commonWords.has(w) && !seen.has(w) && seen.add(w));
  return words.map((w, i) => ({ w, i }))
    .sort((a, b) => [...b.w].length - [...a.w].length || a.i - b.i)
    .slice(0, most).map((x) => x.w);
}

/** The docs most like an item, from one search a word: the most of its words first, then the most
 * matches; none it links to already. A doc two machines found counts once a word. */
export function relatedDocs(searches: readonly (readonly DocsSearchResult[])[], linked: ReadonlySet<string>, most = relatedMost): Doc[] {
  const score = new Map<string, { words: number; matches: number; first: number; doc: Doc }>();
  let order = 0;
  for (const results of searches) {
    const seen = new Set<string>();
    for (const r of results) {
      if (linked.has(r.doc.ref) || seen.has(r.doc.ref)) continue;
      seen.add(r.doc.ref);
      const s = score.get(r.doc.ref) ?? { words: 0, matches: 0, first: order, doc: r.doc };
      s.words += 1;
      s.matches += r.matches.length;
      score.set(r.doc.ref, s);
      order += 1;
    }
  }
  return [...score.values()]
    .sort((a, b) => b.words - a.words || b.matches - a.matches || a.first - b.first)
    .slice(0, most).map((s) => s.doc);
}

export const noDocsHere = "No machine here reads docs yet. Docs come from a folder's Docs slot, in Folder Settings.";
export const noDocs = "No docs. A folder's Markdown files at its top and under specs/ and docs/ show here.";
export const noResults = "No doc has those words.";
