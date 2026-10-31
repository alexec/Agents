// A session's Lineage tab (#2940), as the window's LineagePane: the issues, pull requests,
// helpers and workflow runs the session is linked to, from lineage/walk (depth 2), each with its
// links and, for an issue or a PR, what lineage/cost says was banked on it. Two layouts, behind its
// Layout switch so Alex can compare them (#3019): a tree from this session, and a graph of boxes and
// lines.
import { useSignal } from "@preact/signals";
import type { ComponentChildren } from "preact";
import { useEffect, useRef } from "preact/hooks";
import type { LineageCostRollup, LineageGraph, LineageNode } from "../protocol/generated";
import type { UUID } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import {
  box, costKey, costed, curve, keepStyle, keptStyle, lineageDepth, lineageGraph, lineageNote, lineageStyles, lineageTree, noLineage,
  sessionNode, type GraphNode, type LineageGraphLayout, type LineageRow, type LineageStyle, type TreeRow,
} from "../model/lineage";
import { go, route } from "../route";
import { Choice } from "./Choice";

export function Lineage({ store, host, session }: { store: Store; host: string; session: string }) {
  const graph = useSignal<LineageGraph | null>(null);
  const costs = useSignal<ReadonlyMap<string, LineageCostRollup>>(new Map());
  const failed = useSignal<string | null>(null);
  const asked = useSignal(0);
  const style = useSignal<LineageStyle>(keptStyle());
  const me = sessionNode(session);
  useEffect(() => {
    let current = true;
    failed.value = null;
    void (async () => {
      try {
        const walked = await store.link.call("lineage/walk", { node: me, depth: lineageDepth }, host);
        if (!current) return;
        graph.value = walked;
        // Each issue's and PR's cost, as it comes; a node that will not say is left without one.
        const answers = await Promise.all(walked.nodes.filter(costed).map((node) =>
          store.link.call("lineage/cost", { node }, host).catch(() => null)));
        if (current) costs.value = new Map(answers.flatMap((r) => r ? [[costKey(r.node), r] as const] : []));
      } catch (e) {
        if (current) { graph.value = null; failed.value = describe(e); }
      }
    })();
    return () => { current = false; };
  }, [host, session, asked.value]);

  if (failed.value) return <p class="hint">{failed.value}</p>;
  if (!graph.value) return <p class="hint">Reading the links…</p>;
  const title = (n: LineageNode) =>
    n.kind === "session" ? store.agent(host, n.ref.slice("session:".length))?.title ?? undefined : undefined;
  const empty = !graph.value.nodes.some((n) => n.kind !== me.kind || n.ref !== me.ref);
  // A session this page has goes to its chat; an issue, a PR or a milestone on GitHub opens there (row.url).
  const show = (row: LineageRow) => row.session && store.agent(host, row.session)
    ? () => go({ ...route.value, host, session: row.session as UUID }) : undefined;
  const footer = (
    <>
      {graph.value.limited && <p class="quiet small">The walk stopped at its limit: there are more links.</p>}
      {!empty && <p class="quiet small">{lineageNote}</p>}
    </>
  );
  return (
    <div class={`lineage lineage-${style.value}`}>
      <div class="crumbs">
        <span class="title">Lineage</span>
        <Choice label="Layout" value={style.value} options={lineageStyles}
          title="Show the links as a tree from this session, or as a graph of boxes and lines"
          onPick={(v) => { style.value = v; keepStyle(v); }} />
        <button class="link" onClick={() => { asked.value++; }}>Refresh</button>
      </div>
      {empty ? <p class="hint">{noLineage}</p>
        : style.value === "tree" ? <Tree rows={lineageTree(me, graph.value, costs.value, title)} me={me} show={show} />
        : <Graph layout={lineageGraph(me, graph.value, costs.value, title)} show={show} />}
      {footer}
    </div>
  );
}

type Show = (row: LineageRow) => (() => void) | undefined;

/** A row of the tree: a link to GitHub, a button to a session's chat, or neither. */
function Row({ row, show, children }: { row: LineageRow; show: Show; children: ComponentChildren }) {
  const go = show(row);
  return row.url ? <a class="row lineage-row" href={row.url} target="_blank" rel="noopener noreferrer" title="Open it on GitHub">{children}</a>
    : go ? <button class="row lineage-row" title="Show this session" onClick={go}>{children}</button>
    : <div class="row lineage-row">{children}</div>;
}

/** How far each level of the tree is in, and where the elbow meets a row's dot: LineageLayout's TreeLines. */
const indent = 18, elbow = 15;

/** The tree (#3019): the list's rows, this session at the top, each indented under the node the walk reached it
 * from, with a line from each to its parent. */
function Tree({ rows, me, show }: { rows: TreeRow[]; me: LineageNode; show: Show }) {
  return (
    <ul class="lineage-tree">
      {rows.map((t) => (
        <li key={t.row.node.ref} style={{ paddingLeft: `${indent * (t.depth + 1)}px` }}>
          <TreeLines tree={t} here={t.row.node.kind === me.kind && t.row.node.ref === me.ref} />
          <Row row={t.row} show={show}>
            <span class="title">{t.row.name}</span>
            {t.row.cost && <span class="subtitle lineage-cost">{t.row.cost}</span>}
            {t.row.links.map((line) => <span key={line} class="subtitle">{line}</span>)}
          </Row>
        </li>
      ))}
    </ul>
  );
}

/** The lines before a row of the tree: an ancestor's line going on down past it, the elbow from its parent's line
 * to its dot, and a line down from its dot to its first child. */
function TreeLines({ tree, here }: { tree: TreeRow; here: boolean }) {
  const x = (level: number) => indent * level + indent / 2;
  const parent = x(tree.depth - 1), own = x(tree.depth);
  return (
    <svg class="lineage-lines" width={indent * (tree.depth + 1)} aria-hidden="true">
      {tree.guides.map((on, i) => on && <line key={i} x1={x(i)} x2={x(i)} y1={0} y2="100%" />)}
      {tree.depth > 0 && <line x1={parent} x2={parent} y1={0} y2={tree.last ? elbow : "100%"} />}
      {tree.depth > 0 && <line x1={parent} x2={own - 4} y1={elbow} y2={elbow} />}
      {tree.hasChildren && <line x1={own} x2={own} y1={elbow + 4} y2="100%" />}
      <circle class={here ? "here" : undefined} cx={own} cy={elbow} r={3.5} />
    </svg>
  );
}

/** "alexec/agents#12" in at most `n` letters, cut in the middle as the window's truncationMode(.middle). */
function clip(text: string, n: number): string {
  if (text.length <= n) return text;
  const half = Math.floor((n - 1) / 2);
  return `${text.slice(0, half)}…${text.slice(text.length - (n - 1 - half))}`;
}

/** The graph (#3019): a box for each node, in a tier per kind, a line for each link named by its verb, a box's
 * cost on its second line. It starts as wide as the pane, at most actual size. Drag or scroll to move about;
 * pinch, ctrl-scroll or the buttons to zoom. */
function Graph({ layout, show }: { layout: LineageGraphLayout; show: Show }) {
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
          {layout.nodes.map((n) => <Box key={n.row.node.ref} node={n} show={show} />)}
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

/** One box of the graph: the node's name, and its kind and cost. */
function Box({ node, show }: { node: GraphNode; show: Show }) {
  const inner = (
    <>
      <title>{node.row.name}</title>
      <rect class={node.here ? "box here" : "box"} width={box.width} height={box.height} rx={10} />
      <text class="name" x={10} y={20}>{clip(node.row.name, 28)}</text>
      <text class="detail" x={10} y={38}>{clip(node.detail, 34)}</text>
    </>
  );
  const at = `translate(${node.x},${node.y})`;
  if (node.row.url) {
    return <g class="lineage-box link" transform={at}><a href={node.row.url} target="_blank" rel="noopener noreferrer">{inner}</a></g>;
  }
  const go = show(node.row);
  return <g class={`lineage-box${go ? " link" : ""}`} transform={at} role={go ? "button" : undefined} tabIndex={go ? 0 : undefined}
    onClick={go} onKeyDown={(e) => { if (go && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); go(); } }}>{inner}</g>;
}
