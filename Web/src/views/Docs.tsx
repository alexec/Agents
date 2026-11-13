// Docs (#3321, spec 3319), as the window's DocsView: every machine's docs from docs/list, grouped by
// source (each project, each folder in no project, then each docs connector), a folder's by its
// subfolders, with a Project filter (#3408); search with docs/search, each match's line and snippet
// under its doc; and a doc's page from docs/read, read only, live for a folder's own file.
import { signal, useSignal } from "@preact/signals";
import { useEffect, useMemo, useRef } from "preact/hooks";
import type { Doc, DocsReading, DocsSearchResult, FileReading, Project, WireDate } from "../protocol/generated";
import type { Store } from "../model/store";
import { Capability } from "../protocol/capabilities.generated";
import { describe } from "../model/errors";
import { hostAnswers } from "../model/capabilities";
import { fileURL } from "../model/completions";
import { folderKey } from "../model/groups";
import {
  docStartHelp, docStartLabels, docStartPrompt, docStarts, docStartTitle, docsGroups, docsProjects, docsSortTitle, isFolderDoc,
  linkedRefs, mapItPrompt, mergeResults, mergeSources, noDocs, noDocsHere, noResults, relatedDocs, resultsIn, searchSources, searchWords,
  shortForm, sourceProblem, titleBeside, underShelf, updatedWords, vendorName, windowAddress, type DocStart, type DocsSort,
  type HostDocs, type ProjectOf,
} from "../model/docs";
import { projectName } from "../model/projects";
import { openContextMenu, type MenuItem } from "./ContextMenu";
import { LiveDocument, type OpenPageFile, type PageSource } from "./LiveDocument";
import { isPageFile, pathInFolder } from "../model/pageLink";
import { pathOf } from "./files/paneState";
import { offerStart } from "./NewAgent";
import { go, routeHash } from "../route";

/** The list's state, for the tab: a doc's page goes back to it as it was left. */
const lists = signal<HostDocs[] | null>(null);
const sort = signal<DocsSort>("updated");
const only = signal("");
/** A project's id, or "" for All projects (#3408). */
const inProject = signal("");
/** The organisation's projects, for their names; none without a control plane. */
const projects = signal<Project[]>([]);
const query = signal("");
const asked = signal(0);
/** The line a search match opens a doc's page at, spent once the page has gone there. */
const openAt = signal<{ ref: string; line: number } | undefined>(undefined);
/** The machine a doc was listed on, so its page reads it there first. */
const listedOn = new Map<string, string>();

/** The projects' names, read once a page opens; a folder whose project is not on the list is said by its own name. */
function useProjects(store: Store) {
  useEffect(() => {
    void store.link.call("projects/list", {}).then((l) => { projects.value = l.projects; }, () => undefined);
  }, [store.projectsChanges.value]);
}

/** The project of a machine's folder, by the folder's path, as its summary names it. */
function projectOfIn(store: Store): ProjectOf {
  const all = store.folders.value;
  const list = projects.value;
  return (host, folder) => {
    if (!folder) return undefined;
    const wanted = folderKey(folder.startsWith("/") ? fileURL(folder) : folder);
    const summary = (all[host] ?? []).find((f) => folderKey(f.folder.folder) === wanted);
    if (!summary?.project) return undefined;
    return { id: summary.project, name: projectName(summary.project, list) ?? summary.name };
  };
}

const docsHosts = (store: Store) => store.hosts.value.filter((h) => hostAnswers(h.state) && store.has(h.id, Capability.docs1));

async function readLists(store: Store, hosts: { id: string; name: string }[]): Promise<HostDocs[]> {
  return Promise.all(hosts.map(async (h): Promise<HostDocs> => {
    try {
      const got = await store.link.call("docs/list", { limit: 500 }, h.id);
      for (const d of got.docs) if (!listedOn.has(d.ref)) listedOn.set(d.ref, h.id);
      return { host: h.id, name: h.name, docs: got.docs, sources: got.sources };
    } catch (e) {
      return { host: h.id, name: h.name, docs: [], sources: [], problem: describe(e) };
    }
  }));
}

export function DocsList({ store }: { store: Store }) {
  const hosts = docsHosts(store);
  const hostKey = hosts.map((h) => h.id).join(",");
  const results = useSignal<(DocsSearchResult & { host: string })[] | null>(null);
  const searching = useSignal(false);
  useProjects(store);
  const projectOf = projectOfIn(store);
  const l = lists.value;
  const rows = useMemo(() => (l ? mergeSources(l, projectOf) : []), [l, store.folders.value, projects.value]);
  const shown = rows.filter((r) => (!only.value || r.key === only.value) && (!inProject.value || r.project?.id === inProject.value));
  useEffect(() => {
    let current = true;
    lists.value = null;
    void readLists(store, hosts.map((h) => ({ id: h.id, name: h.name || h.id }))).then((l) => { if (current) lists.value = l; });
    return () => { current = false; };
  }, [hostKey, asked.value]);
  // A search waits for the typing to rest, and an older answer landing late is dropped.
  const words = query.value.trim();
  useEffect(() => {
    if (!words) { results.value = null; return; }
    let current = true;
    searching.value = true;
    const timer = setTimeout(() => {
      // One source is asked of each machine that has a folder of it; a connector of every machine.
      const row = rows.find((r) => r.key === only.value);
      const asking = row ? hosts.filter((h) => searchSources(row, h.id).length > 0) : hosts;
      void Promise.all(asking.map(async (h) => {
        try {
          const sources = row ? searchSources(row, h.id) : undefined;
          const got = await store.link.call("docs/search", { query: words, limit: 50, ...sources ? { sources } : {} }, h.id);
          return { host: h.id, results: got.results };
        } catch {
          return { host: h.id, results: [] };
        }
      })).then((got) => {
        if (!current) return;
        for (const g of got) for (const r of g.results) if (!listedOn.has(r.doc.ref)) listedOn.set(r.doc.ref, g.host);
        results.value = resultsIn(mergeResults(got), shown);
        searching.value = false;
      });
    }, 250);
    return () => { current = false; clearTimeout(timer); };
  }, [words, only.value, inProject.value, hostKey, rows]);

  const groups = useMemo(() => (l ? docsGroups(l, sort.value, only.value, projectOf, inProject.value) : []),
    [l, sort.value, only.value, inProject.value, rows]);
  const projectChoices = docsProjects(rows);
  const sourceChoices = rows.filter((r) => !inProject.value || r.project?.id === inProject.value);
  const problems = (l ?? []).filter((h) => h.problem).map((h) => `${h.name}: ${h.problem}`);
  const open = (doc: Doc, line?: number) => {
    openAt.value = line ? { ref: doc.ref, line } : undefined;
    go({ nav: "docs", section: "docs", item: doc.ref });
  };

  return (
    <div class="work-list docs-list">
      <div class="work-filters" role="group" aria-label="Filters">
        <input type="search" placeholder="Search docs" aria-label="Search docs" value={query.value}
          onInput={(e) => { query.value = (e.target as HTMLInputElement).value; }} />
        {projectChoices.length > 0 && (
          <label>Project <select value={inProject.value} onChange={(e) => {
            inProject.value = (e.target as HTMLSelectElement).value;
            // A source of another project is not in the list any more.
            if (only.value && !rows.some((r) => r.key === only.value && (!inProject.value || r.project?.id === inProject.value))) only.value = "";
          }}>
            <option value="">All projects</option>
            {projectChoices.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </select></label>
        )}
        <label>Source <select value={only.value} onChange={(e) => { only.value = (e.target as HTMLSelectElement).value; }}>
          <option value="">All</option>
          {sourceChoices.map((s) => <option key={s.key} value={s.key}>{s.heading}</option>)}
        </select></label>
        {!words && (
          <label>Sort <select value={sort.value} onChange={(e) => { sort.value = (e.target as HTMLSelectElement).value as DocsSort; }}>
            {(Object.keys(docsSortTitle) as DocsSort[]).map((s) => <option key={s} value={s}>{docsSortTitle[s]}</option>)}
          </select></label>
        )}
        <button type="button" class="link" onClick={() => { asked.value++; }}>Refresh</button>
      </div>
      {problems.map((p) => <p key={p} class="hint">{p}</p>)}
      {hosts.length === 0 ? <p class="hint">{noDocsHere}</p>
        : words ? <Results results={results.value} searching={searching.value} open={open} />
        : l === null ? <p class="hint">Loading…</p>
        : groups.length === 0 ? <p class="hint">{noDocs}</p>
        : groups.map((g) => {
          const problem = sourceProblem(g.source);
          return (
            <section key={g.key} class="docs-source" aria-label={g.heading}>
              <h3 class="docs-source-head">
                <span>{g.heading}</span>
                {g.source.kind === "connector" && problem && <span class="quiet small"> — {problem}</span>}
                {g.source.state === "notMapped" && g.source.folder && (
                  <button type="button" class="link" title="Start an agent that maps this docs server's search and read tools"
                    onClick={() => { offerStart(store, g.host, g.source.folder!, { prompt: mapItPrompt(g.source), labels: [], worktree: undefined }); }}>
                    Map it…</button>
                )}
              </h3>
              {g.source.kind === "folder" && problem && <p class="hint">{problem}</p>}
              {g.source.state === "read" && g.shelves.length === 0 && <p class="quiet small">No docs.</p>}
              {g.shelves.map((s) => (
                <div key={s.dir} class="docs-shelf">
                  {s.dir && <h4 class="docs-shelf-head">▸ {s.dir}</h4>}
                  <ul class={`work-rows${s.dir ? " docs-under" : ""}`}>
                    {s.docs.map((d) => <DocRow key={d.ref} doc={d} name={underShelf(d, s.dir)} open={() => open(d)} />)}
                  </ul>
                </div>
              ))}
            </section>
          );
        })}
    </div>
  );
}

function DocRow({ doc, name, open }: { doc: Doc; name: string; open: () => void }) {
  const beside = titleBeside(doc);
  return (
    <li data-ref={doc.ref}>
      <button type="button" class="work-row docs-row" title={doc.ref} onClick={open}>
        <span class="work-row-head">
          <span class={doc.path ? "docs-path" : "work-title"}>{name}</span>
          {beside && <span class="quiet docs-beside">{beside}</span>}
          <span class="quiet small docs-updated">{updatedWords(doc)}</span>
        </span>
      </button>
    </li>
  );
}

function Results({ results, searching, open }: {
  results: (DocsSearchResult & { host: string })[] | null; searching: boolean; open: (doc: Doc, line?: number) => void;
}) {
  if (results === null) return <p class="hint">{searching ? "Searching…" : ""}</p>;
  if (results.length === 0) return <p class="hint">{searching ? "Searching…" : noResults}</p>;
  return (
    <ul class="work-rows">
      {results.map((r) => (
        <li key={r.doc.ref} data-ref={r.doc.ref}>
          <button type="button" class="work-row docs-row" title={r.doc.ref} onClick={() => open(r.doc)}>
            <span class="work-row-head">
              <span class="work-title">{r.doc.title}</span>
              {r.doc.path && <span class="quiet small docs-path">{r.doc.path}</span>}
            </span>
          </button>
          <ul class="docs-matches">
            {r.matches.map((m, i) => (
              <li key={i}>
                <button type="button" class="link docs-match" onClick={() => open(r.doc, m.line)}>
                  {m.line !== undefined && <span class="docs-line">{m.line}</span>}
                  <span>{m.snippet}</span>
                </button>
              </li>
            ))}
          </ul>
        </li>
      ))}
    </ul>
  );
}

/** How often a folder doc's page reads it again while it is shown: it follows the file as it changes. */
const followEvery = 5_000;

/** A doc's page: its title, ref and when it changed; Open in Files or in its vendor's app, Copy link and
 * Copy ref; and its Markdown, drawn as a live page is, read only. */
export function DocPage({ store, docRef }: { store: Store; docRef: string }) {
  const hosts = docsHosts(store);
  const hostKey = hosts.map((h) => h.id).join(",");
  const got = useSignal<{ host: string; reading: DocsReading } | null>(null);
  const problem = useSignal<string | null>(null);
  const tick = useSignal(0);
  const copied = useSignal<string | null>(null);
  const startProblem = useSignal<string | null>(null);
  const line = openAt.value?.ref === docRef ? openAt.value.line : undefined;
  useProjects(store);

  // The machine that listed it first, then this Mac, then the others.
  const order = useMemo(() => {
    const first = listedOn.get(docRef);
    return [...hosts].sort((a, b) => rank(b.id) - rank(a.id));
    function rank(id: string) { return id === first ? 2 : id === store.macHostID.value ? 1 : 0; }
  }, [docRef, hostKey]);
  useEffect(() => {
    let current = true;
    got.value = null;
    problem.value = null;
    void (async () => {
      let last: string | null = null;
      for (const h of order) {
        try {
          const reading = await store.link.call("docs/read", { ref: docRef }, h.id);
          if (current) got.value = { host: h.id, reading };
          return;
        } catch (e) {
          last = describe(e);
        }
      }
      if (current) problem.value = order.length === 0 ? noDocsHere : last ?? "No machine here has this doc.";
    })();
    return () => { current = false; };
  }, [docRef, hostKey]);

  const doc = got.value?.reading.doc;
  const follows = doc !== undefined && isFolderDoc(doc);
  useEffect(() => {
    if (!follows) return;
    const timer = setInterval(() => { if (document.visibilityState === "visible") tick.value++; }, followEvery);
    return () => clearInterval(timer);
  }, [follows, docRef]);

  // The text the page last had, kept across draws, so a read that brings the same text costs the page nothing.
  const last = useRef<{ ref: string; text: string } | null>(null);
  if (got.value && last.current?.ref !== docRef) last.current = { ref: docRef, text: got.value.reading.text };
  const source: PageSource | undefined = got.value && last.current ? docSource(store, got.value.host, docRef, last.current, tick.value) : undefined;
  const copy = async (what: string, text: string) => {
    try {
      await navigator.clipboard.writeText(text);
      copied.value = what;
      setTimeout(() => { if (copied.peek() === what) copied.value = null; }, 1500);
    } catch {
      copied.value = null;
    }
  };
  const link = location.origin + location.pathname + location.search + routeHash({ nav: "docs", section: "docs", item: docRef });
  const filesPlace = doc && got.value ? folderPlace(store, got.value.host, doc) : undefined;
  // A page in the doc's folder that a link names opens as the folder's page, as Open in Files does (#5068).
  const opens: OpenPageFile | undefined = filesPlace && {
    takes: (file) => { const page = pathInFolder(file, pathOf(filesPlace.folder)); return page !== null && isPageFile(page); },
    open: (file) => { const page = pathInFolder(file, pathOf(filesPlace.folder)); if (page) go({ ...filesPlace, page }); },
  };
  // The project it is in (#3408), as an issue's or a PR's page says it.
  const project = doc && got.value ? projectOfIn(store)(got.value.host, doc.folder) : undefined;

  return (
    <article class="work-page docs-page">
      <div class="work-page-bar">
        <button type="button" title="Back" aria-label="Back" onClick={() => history.back()}>‹</button>
        <button type="button" title="Forward" aria-label="Forward" onClick={() => history.forward()}>›</button>
        <button type="button" class="link" onClick={() => go({ nav: "docs" })}>All docs</button>
      </div>
      <header class="work-page-head">
        <h2><span class="work-title">{doc ? shortForm(doc) : docRef}</span></h2>
        <p class="quiet small">
          {[project?.name ?? "", docRef, doc?.updated !== undefined ? `updated ${updatedWords(doc)}` : ""].filter(Boolean).join(" · ")}
        </p>
        <div class="work-actions-bar">
          {doc && got.value && <StartMenu store={store} host={got.value.host} doc={doc} said={(why) => { startProblem.value = why; }} />}
          {doc?.url && !isFolderDoc(doc)
            ? <a class="button" href={doc.url} target="_blank" rel="noopener noreferrer">Open in {vendorName(docRef)}</a>
            : filesPlace && <button type="button" onClick={() => go(filesPlace)} title="Open this file as the folder's page">Open in Files</button>}
          <button type="button" onClick={() => void copy("link", link)} title={windowAddress(docRef)}>{copied.value === "link" ? "Copied" : "Copy link"}</button>
          <button type="button" onClick={() => void copy("ref", docRef)} title={docRef}>{copied.value === "ref" ? "Copied" : "Copy ref"}</button>
        </div>
        {startProblem.value && <p class="hint failure small" role="status">{startProblem.value}</p>}
      </header>
      {problem.value && <p class="hint">{problem.value}</p>}
      {!got.value && !problem.value && <p class="hint">Reading {docRef}…</p>}
      {got.value && got.value.reading.next !== undefined && (
        <p class="quiet small">Showing lines {got.value.reading.from}–{got.value.reading.to} of {got.value.reading.lines}.</p>
      )}
      {got.value && source && (
        <section class="work-body docs-text" aria-label="Text">
          <LiveDocument store={store} host={got.value.host} agentID="" path={doc?.path ?? doc?.title ?? docRef} line={line} source={source} opens={opens} />
        </section>
      )}
    </article>
  );
}

/** Start Agent ▾ (#3322): a new session from this doc, in its folder; a connector doc's asks for the
 * folder, as a second menu of this machine's folders. */
function StartMenu({ store, host, doc, said }: { store: Store; host: string; doc: Doc; said: (why: string | null) => void }) {
  const folderDoc = isFolderDoc(doc);
  const start = (s: DocStart, folder: string | undefined) => {
    said(folder ? offerStart(store, host, folder, { prompt: docStartPrompt(s, doc.ref), labels: docStartLabels(s, doc), worktree: undefined })
      : "This doc has no folder here.");
  };
  const folders = (s: DocStart): MenuItem[] => (store.folders.value[host] ?? []).map((f) => ({
    label: f.name, run: () => start(s, f.folder.folder),
  }));
  const menu = (event: MouseEvent) => {
    const at = { clientX: event.clientX, clientY: event.clientY };
    openContextMenu(event, docStarts.map((s): MenuItem => ({
      label: folderDoc ? docStartTitle[s] : `${docStartTitle[s]}…`,
      help: docStartHelp[s],
      run: () => {
        if (folderDoc) { start(s, doc.folder); return; }
        const items = folders(s);
        if (items.length === 0) { said("No folder on this machine to start in."); return; }
        // The folder to start in, once the first menu has closed.
        setTimeout(() => openContextMenu(new MouseEvent("click", at), items), 0);
      },
    })));
  };
  return (
    <button type="button" class="prominent" onClick={menu}
      title={folderDoc ? "A new session in this doc's folder, working from it" : "A new session working from this doc, in a folder you choose"}>
      Start Agent ▾</button>
  );
}

/** The Docs section on an issue's and a PR's Work page (#3322), as the window's WorkDocsSection: the
 * docs its body names, then the docs most like its title (docs/search, a search a word). Each opens
 * the doc's page. */
export function WorkDocs({ store, itemRef, title, body, asked }: { store: Store; itemRef: string; title: string; body: string; asked: number }) {
  const hosts = docsHosts(store);
  const hostKey = hosts.map((h) => h.id).join(",");
  const got = useSignal<{ linked: Doc[]; related: Doc[] } | null>(null);
  useEffect(() => {
    let current = true;
    got.value = null;
    void (async () => {
      // Each named doc from the first machine that has it; one it cannot find is left out.
      const linked: Doc[] = [];
      for (const ref of linkedRefs(body, itemRef)) {
        for (const h of hosts) {
          try {
            const r = await store.link.call("docs/read", { ref, from: 1, to: 1 }, h.id);
            if (!listedOn.has(r.doc.ref)) listedOn.set(r.doc.ref, h.id);
            if (!linked.some((l) => l.ref === r.doc.ref)) linked.push(r.doc);
            break;
          } catch { /* the next machine */ }
        }
      }
      const searches = await Promise.all(searchWords(title).map(async (word) => (await Promise.all(hosts.map(async (h) => {
        try {
          const r = await store.link.call("docs/search", { query: word, limit: 20 }, h.id);
          for (const x of r.results) if (!listedOn.has(x.doc.ref)) listedOn.set(x.doc.ref, h.id);
          return r.results;
        } catch {
          return [];
        }
      }))).flat()));
      if (current) got.value = { linked, related: relatedDocs(searches, new Set(linked.map((l) => l.ref))) };
    })();
    return () => { current = false; };
  }, [itemRef, body, title, hostKey, asked]);

  if (hosts.length === 0) return null;
  const g = got.value;
  // A section of the page's side panel (#4402): the panel is narrow, so the title goes under the doc's name.
  const row = (doc: Doc) => {
    const beside = titleBeside(doc);
    return (
      <li key={doc.ref} data-ref={doc.ref}>
        <button type="button" class="work-doc-row" title={doc.ref} onClick={() => go({ nav: "docs", section: "docs", item: doc.ref })}>
          <span aria-hidden="true" class="quiet">▤</span>
          <span class="work-doc-words">
            <span class={doc.path ? "docs-path" : undefined}>{shortForm(doc)}</span>
            {beside && <span class="quiet small">{beside}</span>}
          </span>
        </button>
      </li>
    );
  };
  return (
    <section class="work-side-section work-docs" aria-label="Docs">
      <h3>Docs</h3>
      <div class="value">
        {!g ? <span class="quiet">Finding its docs…</span>
          : g.linked.length === 0 && g.related.length === 0 ? <span class="quiet">None</span>
          : (
            <>
              {g.linked.length > 0 && <ul class="work-doc-rows">{g.linked.map(row)}</ul>}
              {g.related.length > 0 && <>
                <span class="quiet small">Like it</span>
                <ul class="work-doc-rows">{g.related.map(row)}</ul>
              </>}
            </>
          )}
      </div>
    </section>
  );
}

/** A doc as a live page reads it: docs/read again at each tick, the same text "unchanged". Read only. */
function docSource(store: Store, host: string, ref: string, last: { text: string }, tick: number): PageSource {
  return {
    read: async (stamp) => {
      const text = stamp ? (await store.link.call("docs/read", { ref }, host)).text : last.text;
      const now: FileReading = text === last.text && stamp
        ? { kind: "unchanged", stamp }
        : { kind: "text", text, stamp: { size: text.length, modifiedAt: Date.now() as WireDate }, isTruncated: false, size: text.length };
      last.text = text;
      return now;
    },
    write: async () => false,
    watch: () => () => {},
    changed: tick || undefined,
    readOnly: true,
  };
}

/** Where Open in Files goes: the folder's own page of the file, as a pinned page opens. */
function folderPlace(store: Store, host: string, doc: Doc) {
  if (!doc.folder || !doc.path) return undefined;
  const wanted = folderKey(doc.folder.startsWith("/") ? fileURL(doc.folder) : doc.folder);
  const summary = (store.folders.value[host] ?? []).find((p) => folderKey(p.folder.folder) === wanted);
  return summary ? { host, folder: summary.folder.folder, page: doc.path } : undefined;
}
