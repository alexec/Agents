// Reports ▸ Planning ▸ Delivery (#5245, spec 5239-deploy-model, board 5): the four DORA figures for each target, a
// component in one environment, on one tier. The figures are deploys/delivery, asked of each of the person's machines
// that keeps deploys; the one that keeps the most answers, as Builds does. The words are model/deploys.ts.
import { useEffect, useRef } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { DeploysDelivery, MachineRef } from "../protocol/generated";
import { Capability } from "../protocol/capabilities.generated";
import type { Store } from "../model/store";
import { hostAnswers } from "../model/capabilities";
import { replace, route } from "../route";
import { ranges, rangeSpan } from "../model/reports";
import {
  askLine, deployTiles, deploysNote, deploysQuery, fewDeploys, fewWords, noDeployMachine, noTargetsWords, parseDeploysQuery,
  resolvingWords, targetLine, targetTitle, tierOptions, type DeploysAsk,
} from "../model/deploys";
import { CallFailed } from "../wire/link";
import { Choice } from "./Choice";
import { LastUpdate } from "./LastUpdate";

const at = (a: DeploysAsk) => ({ nav: "reports" as const, section: "value", item: "delivery", query: deploysQuery(a) });

function failed(error: unknown): string {
  if (error instanceof CallFailed) return error.code === -32601 ? "This machine does not count deploys. Update it to see them." : error.message;
  return "The machine can’t be reached.";
}

/** What the page read: the answer in the tier, how many targets every tier has, and when. */
interface Read { host: MachineRef; delivery: DeploysDelivery; everyTier: number; readAt: number; key: string }

export function DeliveryPage({ store, down }: { store: Store; down: boolean }) {
  const ask = parseDeploysQuery(route.value.query);
  const hosts = store.hosts.value.filter((h) => hostAnswers(h.state) && store.has(h.id, Capability.deploysDelivery1)).map((h) => h.id);
  const mac = store.macHostID.value;
  // This Mac first, so a tie goes to it.
  hosts.sort((a, b) => Number(b === mac) - Number(a === mac));
  const read = useSignal<Read | null>(null);
  const problem = useSignal<string | null>(null);
  const hostKey = hosts.join(" ");
  const wanted = JSON.stringify([ask.range, ask.tier, hostKey]);
  const current = useRef(wanted);
  current.current = wanted;

  useEffect(() => {
    if (down || hosts.length === 0) return;
    problem.value = null;
    let again: ReturnType<typeof setTimeout> | undefined;
    const load = () => {
      const asked = { range: ask.range };
      void Promise.all(hosts.map((host) => store.link.call("deploys/delivery", asked, host).then((delivery) => ({ host, delivery }), (e: unknown) => e)))
        .then((got) => {
          if (current.current !== wanted) return;
          const answers = got.filter((g): g is { host: MachineRef; delivery: DeploysDelivery } => typeof g === "object" && g !== null && "delivery" in g);
          const best = answers.sort((a, b) => b.delivery.deploys - a.delivery.deploys)[0];
          if (!best) { problem.value = failed(got[0]); return; }
          // Every tier is asked, and the tier picked is taken from it, so the empty words can say what other tiers have.
          const all = best.delivery;
          const targets = ask.tier ? all.targets.filter((t) => t.tier === ask.tier) : all.targets;
          read.value = { host: best.host, delivery: { ...all, targets }, everyTier: all.targets.length, readAt: Date.now(), key: wanted };
          // What some deploys brought is still being asked: read again once it has had time.
          if (all.resolving) again = setTimeout(load, 5_000);
        });
    };
    load();
    return () => { if (again) clearTimeout(again); };
  }, [wanted, down]);

  if (down) return <p class="hint">The control plane can’t be reached.</p>;
  if (hosts.length === 0) return <p class="hint">{noDeployMachine}</p>;
  const shown = read.value?.key === wanted ? read.value : null;
  const d = shown?.delivery;
  const days = d ? Number(d.windowDays) : 0;
  const set = (change: Partial<DeploysAsk>) => replace(at({ ...ask, ...change }));
  return (
    <div class="reports-pane deploys-page">
      {shown && <LastUpdate at={shown.readAt} />}
      <div class="builds-filters">
        <Choice label="Range" value={ask.range} options={ranges.filter((r) => r !== "day").map((r) => [r, rangeSpan[r]] as const)} onPick={(r) => set({ range: r })} />
        <Choice label="Tier" value={ask.tier} options={tierOptions} onPick={(t) => set({ tier: t })} />
      </div>
      <p class="quiet small">{askLine(rangeSpan[ask.range], ask)}</p>
      {problem.value && <p class="hint">{problem.value}</p>}
      {!d && !problem.value && <p class="hint">Loading…</p>}
      {d && d.targets.length === 0 && <p class="hint">{noTargetsWords(ask, rangeSpan[ask.range], shown.everyTier)}</p>}
      {d?.targets.map((t) => {
        const few = t.ended < fewDeploys;
        return (
          <section key={`${t.component}@${t.environmentRef}`} class={`deploys-target${few ? " few" : ""}`}>
            <div class="deploys-target-head">
              <h3>{targetTitle(t)}</h3>
              <span class="quiet small">{targetLine(t, days)}</span>
            </div>
            <ul class="delivery-cards deploys-tiles">
              {deployTiles(t).map((tile) => (
                <li key={tile.key} class="delivery-card">
                  <span class="quiet small">{tile.title}</span>
                  <span class="delivery-value strong">{tile.value}</span>
                  <span class="quiet small">{tile.detail}</span>
                </li>
              ))}
            </ul>
            {few && <p class="quiet small deploys-few">{fewWords(t)}</p>}
          </section>
        );
      })}
      {d?.resolving && <p class="quiet small">{resolvingWords}</p>}
      {d && d.targets.length > 0 && <p class="quiet small">{deploysNote}</p>}
    </div>
  );
}
