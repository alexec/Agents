// A session's Lineage tab (#2940), as the window's LineagePane: the issues, pull requests,
// helpers and workflow runs the session is linked to, from lineage/walk (depth 2), each with its
// links and, for an issue or a PR, what lineage/cost says was banked on it. A list, no graph.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { LineageCostRollup, LineageGraph } from "../protocol/generated";
import type { UUID } from "../protocol/generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import { costKey, costed, lineageDepth, lineageGroups, lineageNote, noLineage, sessionNode } from "../model/lineage";
import { go, route } from "../route";

export function Lineage({ store, host, session }: { store: Store; host: string; session: string }) {
  const graph = useSignal<LineageGraph | null>(null);
  const costs = useSignal<ReadonlyMap<string, LineageCostRollup>>(new Map());
  const failed = useSignal<string | null>(null);
  const asked = useSignal(0);
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
  const groups = lineageGroups(me, graph.value, costs.value, (n) =>
    n.kind === "session" ? store.agent(host, n.ref.slice("session:".length))?.title ?? undefined : undefined);
  return (
    <div class="lineage">
      <div class="crumbs">
        <span class="title">Lineage</span>
        <button class="link" onClick={() => { asked.value++; }}>Refresh</button>
      </div>
      {groups.length === 0 ? <p class="hint">{noLineage}</p> : groups.map((group) => (
        <section key={group.title} aria-label={group.title}>
          <h3 class="lineage-head">{group.title}</h3>
          <ul>
            {group.rows.map((row) => {
              const inner = (
                <>
                  <span class="title">{row.name}</span>
                  {row.cost && <span class="subtitle lineage-cost">{row.cost}</span>}
                  {row.links.map((line) => <span key={line} class="subtitle">{line}</span>)}
                </>
              );
              return (
                <li key={row.node.ref}>
                  {/* A session goes to its chat; an issue, a PR or a milestone on GitHub opens there. */}
                  {row.url ? <a class="row lineage-row" href={row.url} target="_blank" rel="noopener noreferrer" title="Open it on GitHub">{inner}</a>
                    : row.session && store.agent(host, row.session) ? <button class="row lineage-row" title="Show this session"
                    onClick={() => go({ ...route.value, host, session: row.session as UUID })}>{inner}</button>
                    : <div class="row lineage-row">{inner}</div>}
                </li>
              );
            })}
          </ul>
        </section>
      ))}
      {graph.value.limited && <p class="quiet small">The walk stopped at its limit: there are more links.</p>}
      {groups.length > 0 && <p class="quiet small">{lineageNote}</p>}
    </div>
  );
}
