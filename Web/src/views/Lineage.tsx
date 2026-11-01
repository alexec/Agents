// A session's Lineage tab (#2940), as the window's LineagePane: the issues, pull requests,
// helpers and workflow runs the session is linked to, from lineage/walk (depth 2), each with its
// links and, for an issue or a PR, what lineage/cost says was banked on it, as a graph of boxes
// and lines (#3019). And Reports ▸ Lineage (#3087), as the window's LineagePage: the same graph
// from any start, a click on a box starting from it, with Back and Forward along the starts.
import { signal, useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import type { LineageCostRollup, LineageGraph, LineageNode } from "../protocol/generated";
import type { UUID } from "../protocol/generated";
import type { Store } from "../model/store";
import { Capability } from "../protocol/capabilities.generated";
import { describe } from "../model/errors";
import {
  box, costKey, costed, curve, currentStart, emptyHistory, goBack, goForward, goTo, kindWord, lineageDepth, lineageGraph,
  lineageNote, lineagePageNote, noLineage, noLineageHere, readingTitles, resolvingAsks, sessionHost, sessionNode, startRow, typedNode, typedPullRequest, type GraphNode, type LineageGraphLayout,
  type LineageHistory, type LineageRow,
} from "../model/lineage";
import { go, route } from "../route";

/** The walk and the costs from a node on a host, asked again when either or `asked` changes. */
function useWalk(store: Store, host: string | undefined, node: LineageNode | undefined, asked: number) {
  const graph = useSignal<LineageGraph | null>(null);
  const costs = useSignal<ReadonlyMap<string, LineageCostRollup>>(new Map());
  const failed = useSignal<string | null>(null);
  const reading = useSignal(false);
  useEffect(() => {
    let current = true;
    failed.value = null;
    reading.value = false;
    graph.value = null;
    costs.value = new Map();
    if (!host || !node) return;
    void (async () => {
      try {
        const walked = await store.link.call("lineage/walk", { node, depth: lineageDepth }, host);
        if (!current) return;
        graph.value = walked;
        // Each issue's and PR's cost, as it comes; a node that will not say is left without one.
        const answers = await Promise.all(walked.nodes.filter(costed).map((n) =>
          store.link.call("lineage/cost", { node: n }, host).catch(() => null)));
        if (current) costs.value = new Map(answers.flatMap((r) => r ? [[costKey(r.node), r] as const] : []));
        // The daemon resolves issues' and PRs' titles in the background (#3102): walk again while it says
        // some are still to come. One failed walk keeps the graph that is shown and stops asking (#3154).
        let latest = walked;
        reading.value = !!latest.resolving;
        try {
          for (let i = 0; current && latest.resolving && i < resolvingAsks; i++) {
            await new Promise((done) => setTimeout(done, 1000));
            if (!current) return;
            latest = await store.link.call("lineage/walk", { node, depth: lineageDepth }, host);
            if (current) graph.value = latest;
          }
        } catch {
          // Keep the last graph.
        }
        if (current) reading.value = false;
      } catch (e) {
        if (current) { graph.value = null; failed.value = describe(e); }
      }
    })();
    return () => { current = false; };
  }, [host, node?.kind, node?.ref, asked]);
  return { graph, costs, failed, reading };
}

const sessionTitle = (store: Store, host: string) => (n: LineageNode) =>
  n.kind === "session" ? store.agent(host, n.ref.slice("session:".length))?.title ?? undefined : undefined;

export function Lineage({ store, host, session }: { store: Store; host: string; session: string }) {
  const asked = useSignal(0);
  const me = sessionNode(session);
  const { graph, costs, failed, reading } = useWalk(store, host, me, asked.value);

  // The crumbs are always there (#3155): after a failed read, Refresh is how to read again.
  let body;
  if (failed.value) {
    body = <p class="hint">{failed.value}</p>;
  } else if (!graph.value) {
    body = <p class="hint">Reading the links…</p>;
  } else {
    const title = sessionTitle(store, host);
    const empty = !graph.value.nodes.some((n) => n.kind !== me.kind || n.ref !== me.ref);
    // A session this page has goes to its chat; an issue, a PR or a milestone on GitHub opens there (row.url).
    const show = (row: LineageRow) => row.session && row.session !== session && store.agent(host, row.session)
      ? () => go({ ...route.value, host, session: row.session as UUID }) : undefined;
    body = (
      <>
        {empty ? <p class="hint">{noLineage}</p> : <Graph layout={lineageGraph(me, graph.value, costs.value, title)} show={show}
          verb={(row) => row.url ? "Open it on GitHub" : "Show this session"} />}
        {reading.value && <p class="quiet small">{readingTitles}</p>}
        {graph.value.limited && <p class="quiet small">The walk stopped at its limit: there are more links.</p>}
        {!empty && <p class="quiet small">{lineageNote}</p>}
      </>
    );
  }
  return (
    <div class="lineage">
      <div class="crumbs">
        <span class="title">Lineage</span>
        <button class="link" title="Open it on Reports ▸ Lineage, where a click on a box starts from it"
          onClick={() => { exploreFrom({ host, node: me }); }}>Explore</button>
        <button class="link" title="Read the links and the costs again" onClick={() => { asked.value++; }}>Refresh</button>
      </div>
      {body}
    </div>
  );
}

/** The start for "owner/repo#12" (#3148): the issue, unless it has no links and the pull request of that number has. */
async function issueOrPullRequest(store: Store, host: string, issue: LineageNode, pr: LineageNode | undefined): Promise<LineageNode> {
  if (!pr) return issue;
  const linked = (node: LineageNode) => store.link.call("lineage/walk", { node, depth: 1 }, host)
    .then((g) => g.links.length > 0, () => false);
  return !(await linked(issue)) && await linked(pr) ? pr : issue;
}

/** A start of the Lineage page: a node, and the host whose links are walked from it. */
interface Place { host: string; node: LineageNode }
const samePlace = (a: Place, b: Place) => a.host === b.host && a.node.kind === b.node.kind && a.node.ref === b.node.ref;

/** The Lineage page's starts, kept while the tab is open, so going back to the page goes back to where it was. */
const history = signal<LineageHistory<Place>>(emptyHistory());

/** Open Reports ▸ Lineage from a place: a session pane's Explore. */
export function exploreFrom(place: Place): void {
  history.value = goTo(history.value, place, samePlace);
  go({ nav: "reports", section: "lineage" });
}

/** Reports ▸ Lineage (#3087): the graph from any start, a click on a box starting from it. */
export function LineagePage({ store }: { store: Store }) {
  const typed = useSignal("");
  const wrong = useSignal(false);
  const asked = useSignal(0);
  const hosts = store.hosts.value.filter((h) => store.has(h.id, Capability.lineage1));
  const chosen = useSignal<string | undefined>(undefined);
  const machine = chosen.value && hosts.some((h) => h.id === chosen.value) ? chosen.value
    : hosts.find((h) => h.id === store.macHostID.value)?.id ?? hosts[0]?.id;
  // With nothing walked yet, the session open is where it starts.
  useEffect(() => {
    const r = route.value;
    if (!currentStart(history.value) && r.host && r.session) history.value = goTo(history.value, { host: r.host, node: sessionNode(r.session) }, samePlace);
  }, []);
  const place = currentStart(history.value);
  const { graph, costs, failed, reading } = useWalk(store, place?.host, place?.node, asked.value);
  const startFrom = (p: Place) => { wrong.value = false; history.value = goTo(history.value, p, samePlace); };
  const sessions = store.hosts.value.flatMap((h) => (store.agents.value[h.id] ?? []).filter((a) => !a.archivedAt)
    .map((a) => ({ host: h.id, agent: a }))).sort((a, b) => b.agent.lastActivityAt - a.agent.lastActivityAt).slice(0, 15);
  const submit = async () => {
    const text = typed.value;
    const node = typedNode(text);
    if (!node) { wrong.value = true; return; }
    const owner = node.kind === "session" ? sessionHost(store.agents.value, node.ref.slice("session:".length)) : undefined;
    const host = owner ?? machine;
    if (!host) return;
    typed.value = "";
    startFrom({ host, node: await issueOrPullRequest(store, host, node, typedPullRequest(text)) });
  };
  const title = place ? sessionTitle(store, place.host) : () => undefined;
  const bar = (
    <form class="lineage-bar" onSubmit={(e) => { e.preventDefault(); void submit(); }}>
      <button type="button" title="Back: the start before this one" aria-label="Back" disabled={history.value.at <= 0}
        onClick={() => { history.value = goBack(history.value); }}>‹</button>
      <button type="button" title="Forward" aria-label="Forward" disabled={history.value.at + 1 >= history.value.places.length}
        onClick={() => { history.value = goForward(history.value); }}>›</button>
      <input type="text" value={typed.value} aria-label="Start from"
        placeholder="An issue’s, a pull request’s, a milestone’s or a release’s address, or owner/repo#12"
        onInput={(e) => { typed.value = (e.target as HTMLInputElement).value; wrong.value = false; }} />
      {hosts.length > 1 && (
        <select aria-label="Machine" title="The machine whose links are walked" value={machine}
          onChange={(e) => { chosen.value = (e.target as HTMLSelectElement).value; }}>
          {hosts.map((h) => <option key={h.id} value={h.id}>{h.name}</option>)}
        </select>
      )}
      <select aria-label="Start from a session" title="Start from one of your sessions" value="" disabled={sessions.length === 0}
        onChange={(e) => {
          const s = sessions[Number((e.target as HTMLSelectElement).value)];
          if (s) startFrom({ host: s.host, node: sessionNode(s.agent.id) });
        }}>
        <option value="">Session</option>
        {sessions.map((s, i) => <option key={`${s.host}|${s.agent.id}`} value={i}>{s.agent.title ?? "Untitled"}</option>)}
      </select>
      <button type="button" class="link" disabled={!place} onClick={() => { asked.value++; }}>Refresh</button>
    </form>
  );
  let body;
  if (wrong.value) {
    body = <p class="hint">That is not an address Lineage knows. Type a GitHub issue’s, pull request’s, milestone’s or release’s address, owner/repo#12, or a session’s id.</p>;
  } else if (hosts.length === 0) {
    body = <p class="hint">No machine keeps links yet. Update Agents on a machine to see them.</p>;
  } else if (!place) {
    body = <p class="hint">Start from a session, or type an issue’s, a pull request’s, a milestone’s or a release’s address. Then click a box to start from it.</p>;
  } else if (failed.value) {
    body = <p class="hint">{failed.value}</p>;
  } else if (!graph.value) {
    body = <p class="hint">Reading the links…</p>;
  } else {
    const walked = graph.value;
    const here = startRow(place.node, walked, costs.value, title);
    const layout = lineageGraph(place.node, walked, costs.value, title);
    const chat = here.session ? store.agent(place.host, here.session) : undefined;
    body = (
      <>
        <div class="lineage-start">
          <strong title={here.ref ?? here.name}>{place.node.kind === "session" ? title(place.node) ?? "A session" : here.name}</strong>
          <span class="quiet">{[kindWord(place.node.kind), ...here.cost ? [here.cost] : [], ...here.resolved ? [here.resolved] : []].join(" · ")}</span>
          {here.url ? <a class="link" href={here.url} target="_blank" rel="noopener noreferrer">Open on GitHub</a>
            : chat && <button class="link" onClick={() => go({ host: place.host, folder: chat.worktree?.folder || chat.cwd, session: chat.id })}>Show the chat</button>}
        </div>
        {layout.nodes.length === 0 ? <p class="hint">{noLineageHere}</p> : (
          <Graph layout={layout} verb={() => "Start from it"}
            show={(row) => row.node.kind === place.node.kind && row.node.ref === place.node.ref ? undefined
              : () => startFrom({ host: row.session ? sessionHost(store.agents.value, row.session) ?? place.host : place.host, node: row.node })} />
        )}
        {reading.value && <p class="quiet small">{readingTitles}</p>}
        {walked.limited && <p class="quiet small">The walk stopped at its limit: there are more links.</p>}
        {layout.nodes.length > 0 && <p class="quiet small">{lineagePageNote}</p>}
      </>
    );
  }
  return <div class="lineage lineage-page">{bar}{body}</div>;
}

type Show = (row: LineageRow) => (() => void) | undefined;

/** "alexec/agents#12" in at most `n` letters, cut in the middle as the window's truncationMode(.middle). */
function clip(text: string, n: number): string {
  if (text.length <= n) return text;
  const half = Math.floor((n - 1) / 2);
  return `${text.slice(0, half)}…${text.slice(text.length - (n - 1 - half))}`;
}

/** The graph (#3019): a box for each node, in a tier per kind, a line for each link named by its verb, a box's
 * cost on its second line. It starts as wide as the pane, at most actual size. Drag or scroll to move about;
 * pinch, ctrl-scroll or the buttons to zoom. */
function Graph({ layout, show, verb }: { layout: LineageGraphLayout; show: Show; verb: (row: LineageRow) => string }) {
  const view = useSignal({ x: 0, y: 0, k: 1 });
  const svg = useRef<SVGSVGElement>(null);
  const drag = useRef<{ id: number; x: number; y: number } | null>(null);
  const fit = () => {
    const w = svg.current?.clientWidth ?? 0;
    view.value = { x: 0, y: 0, k: w > 0 ? Math.min(Math.max(Math.min(1, w / Math.max(layout.width, 1)), 0.4), 2.5) : 1 };
  };
  useEffect(fit, [layout.width]);
  const zoomTo = (k: number, at?: { x: number; y: number }) => {
    const { x, y, k: was } = view.value;
    const next = Math.min(Math.max(k, 0.4), 2.5);
    const p = at ?? { x: 0, y: 0 };
    view.value = { x: p.x - (p.x - x) * (next / was), y: p.y - (p.y - y) * (next / was), k: next };
  };
  const { x, y, k } = view.value;
  return (
    <div class="lineage-graph">
      <div class="lineage-zoom" role="group" aria-label="Zoom">
        <button title="Zoom out" aria-label="Zoom out" onClick={() => zoomTo(k / 1.25)}>−</button>
        <button title="Fit the pane's width" onClick={fit}>{Math.round(k * 100)}%</button>
        <button title="Zoom in" aria-label="Zoom in" onClick={() => zoomTo(k * 1.25)}>+</button>
      </div>
      <svg ref={svg} class={drag.current ? "dragging" : undefined} width="100%" height={Math.max(layout.height * k, 240)}
        onWheel={(e) => {
          e.preventDefault();
          if (e.ctrlKey || e.metaKey) {
            const r = svg.current!.getBoundingClientRect();
            zoomTo(k * Math.exp(-e.deltaY / 200), { x: e.clientX - r.left, y: e.clientY - r.top });
          } else view.value = { x: x - e.deltaX, y: y - e.deltaY, k };
        }}
        onPointerDown={(e) => {
          if (e.target !== svg.current && !(e.target as Element).classList.contains("lineage-ground")) return;
          drag.current = { id: e.pointerId, x: e.clientX, y: e.clientY };
          svg.current!.setPointerCapture(e.pointerId);
        }}
        onPointerMove={(e) => {
          const d = drag.current;
          if (!d || d.id !== e.pointerId) return;
          view.value = { x: x + e.clientX - d.x, y: y + e.clientY - d.y, k };
          drag.current = { ...d, x: e.clientX, y: e.clientY };
        }}
        onPointerUp={() => { drag.current = null; }} onPointerCancel={() => { drag.current = null; }}>
        <defs>
          <marker id="lineage-arrow" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
            <path d="M0,0 L8,4 L0,8 z" />
          </marker>
        </defs>
        <rect class="lineage-ground" width="100%" height="100%" />
        <g transform={`translate(${x},${y}) scale(${k})`}>
          {layout.edges.map((e) => {
            const c = curve(layout, e);
            if (!c) return null;
            return (
              <g key={`${e.from}\n${e.label}\n${e.to}`} class={`lineage-edge${e.ended ? " ended" : ""}`}>
                <path d={`M${c.start.x},${c.start.y} C${c.c1.x},${c.c1.y} ${c.c2.x},${c.c2.y} ${c.end.x},${c.end.y}`} marker-end="url(#lineage-arrow)" />
              </g>
            );
          })}
          {layout.nodes.map((n) => <Box key={n.row.node.ref} node={n} show={show} verb={verb} />)}
          {/* The verbs over the boxes: a line that skips a tier passes under one. */}
          {layout.edges.map((e) => {
            const c = curve(layout, e);
            return c && <text key={`${e.from}\n${e.label}\n${e.to}`} class="lineage-verb" x={c.mid.x} y={c.mid.y}
              text-anchor="middle" dominant-baseline="central">{e.label}</text>;
          })}
        </g>
      </svg>
    </div>
  );
}

/** One box of the graph: the node's name, and its kind and cost; its name, ref, the whole of that line and its links,
 * one a line, in its title (#3159). A box that `show` gives a click to is a button; else an issue's or a PR's opens on
 * GitHub. */
function Box({ node, show, verb }: { node: GraphNode; show: Show; verb: (row: LineageRow) => string }) {
  const go = show(node.row);
  const inner = (
    <>
      <title>{[node.row.name, ...node.row.ref ? [node.row.ref] : [], node.detail, ...node.row.links, ...go || node.row.url ? [verb(node.row)] : []].join("\n")}</title>
      <rect class={node.here ? "box here" : "box"} width={box.width} height={box.height} rx={10} />
      <text class="name" x={10} y={20}>{clip(node.row.name, 28)}</text>
      <text class="detail" x={10} y={38}>{clip(node.detail, 34)}</text>
    </>
  );
  const at = `translate(${node.x},${node.y})`;
  if (!go && node.row.url) {
    return <g class="lineage-box link" transform={at}><a href={node.row.url} target="_blank" rel="noopener noreferrer">{inner}</a></g>;
  }
  return <g class={`lineage-box${go ? " link" : ""}`} transform={at} role={go ? "button" : undefined} tabIndex={go ? 0 : undefined}
    onClick={go} onKeyDown={(e) => { if (go && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); go(); } }}>{inner}</g>;
}
