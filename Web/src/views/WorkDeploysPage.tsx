// Work ▸ Deploys (#5270, spec 5239-deploy-model board 4), as the window's WorkDeploysPane: the environments across in
// tier order, the components down, each cell a target with its live versions, since when, and what goes next. A click on
// a cell opens the deploy's job; on a version, its release's page. The state lives for the tab, so Back from a release's
// page finds the page as it was left.
import { signal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { DeployOnTarget, DeployTargetNow, DeployTargets } from "../protocol/generated";
import { Capability } from "../protocol/capabilities.generated";
import type { Store } from "../model/store";
import { describe } from "../model/errors";
import { hostAnswers } from "../model/capabilities";
import {
  cellLabel, clickNote, deployGrid, emptyLine, emptyTitle, jobOf, labelsLine, mergeTargets, nextWords, noLive, noMachine, shareWords,
  sinceWords, tierChip, versionWords,
} from "../model/workDeploys";
import { keepWork, keptWorkRead } from "../model/localCopy";
import { go } from "../route";
import { LastUpdate } from "./LastUpdate";
import { EmptyState, ErrorStrip, FromDeviceStrip, PlaceholderRows, RefreshButton } from "./WorkParts";

const targets = signal<DeployTargetNow[] | null>(null);
const problem = signal<string | null>(null);
const reading = signal(false);
const asked = signal(0);
/** When what is on screen was read (#5139): this device's copy's time, or the last read. */
const readAt = signal<number | undefined>(undefined);
/** What is on screen came from this device's copy (#4930), until the machines answer. */
const fromDevice = signal(false);
const kept = "all";

/** The machines that say their deploys' targets (`deploys.targets/1`). */
const deployHosts = (store: Store) => store.hosts.value.filter((h) => hostAnswers(h.state) && store.has(h.id, Capability.deploysTargets1));

async function load(store: Store) {
  const mine = asked.value;
  reading.value = true;
  try {
    if (targets.value === null) {
      const copy = await keptWorkRead<DeployTargetNow[]>("deploys", kept);
      if (copy && asked.value === mine && targets.value === null) {
        targets.value = copy.value;
        readAt.value = copy.at;
        fromDevice.value = true;
      }
    }
    const hosts = deployHosts(store);
    const answers = await Promise.all(hosts.map(async (h) => {
      try {
        const got: DeployTargets = await store.link.call("deploys/targets", {}, h.id);
        return { got: got.targets };
      } catch (e) {
        return { failed: hosts.length > 1 ? `${h.name}: ${describe(e)}` : describe(e) };
      }
    }));
    if (asked.value !== mine) return;
    const failed = answers.flatMap((a) => a.failed ? [a.failed] : []);
    const got = answers.flatMap((a) => a.got ? [a.got] : []);
    problem.value = failed.length ? failed.join("\n") : null;
    // Every machine failed: what is on screen stays, with its time in the strip.
    if (got.length === 0 && failed.length > 0) return;
    const merged = mergeTargets(got);
    targets.value = merged;
    readAt.value = Date.now();
    fromDevice.value = false;
    if (failed.length === 0) keepWork("deploys", kept, merged);
  } finally {
    if (asked.value === mine) reading.value = false;
  }
}

export function WorkDeploysPage({ store }: { store: Store }) {
  const hosts = deployHosts(store).map((h) => h.id).join(",");
  useEffect(() => { void load(store); }, [asked.value, hosts]);
  // Read again every minute, so a deploy that lands shows while the page is open.
  useEffect(() => {
    const t = setInterval(() => { asked.value++; }, 60_000);
    return () => clearInterval(t);
  }, []);
  const refresh = () => { asked.value++; };
  const t = targets.value;
  return (
    <div class="work-list deploys-page">
      <div class="deploys-bar">
        {readAt.value !== undefined && !fromDevice.value ? <LastUpdate at={readAt.value} /> : <span />}
        <RefreshButton busy={reading.value} onClick={refresh} />
      </div>
      <FromDeviceStrip at={fromDevice.value ? readAt.value : undefined} />
      <ErrorStrip lines={problem.value ? problem.value.split("\n") : []} retry={refresh} at={readAt.value} />
      {hosts === "" ? <EmptyState kind="deploy" title="No machine keeps deploys" line={noMachine} />
        : t === null ? (problem.value ? null : <PlaceholderRows />)
        : <Grid targets={t} />}
    </div>
  );
}

function Grid({ targets: all }: { targets: readonly DeployTargetNow[] }) {
  const grid = deployGrid(all);
  if (grid.rows.length === 0) return <EmptyState kind="deploy" title={emptyTitle} line={emptyLine} />;
  return (
    <>
      <div class="deploys-scroll">
        <table class="deploys-grid">
          <thead>
            <tr>
              <th scope="col"><span class="visually-hidden">Component</span></th>
              {grid.columns.map((c) => {
                const chip = tierChip(c.tier);
                return <th key={c.name} scope="col"><span class="strong">{c.name}</span>{chip && <span class="deploys-tier">{chip}</span>}</th>;
              })}
            </tr>
          </thead>
          <tbody>
            {grid.rows.map((row) => (
              <tr key={row.id}>
                <th scope="row">{row.name}</th>
                {grid.columns.map((c, i) => {
                  const cell = row.cells[i] ?? [];
                  return (
                    <td key={c.name} aria-label={cellLabel(row.name, c.name, cell)}>
                      {cell.length === 0 ? <span class="quiet deploys-none" aria-hidden="true">–</span>
                        : cell.map((tn) => <Card key={labelsLine(tn.target)} target={tn} />)}
                    </td>
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p class="quiet deploys-note">{clickNote}</p>
    </>
  );
}

/** One target in a cell: its labels, each live version (with its share when the traffic is split) and since when, and each
 * next deploy. The card opens the newest deploy's job; a release's version opens its page. */
function Card({ target }: { target: DeployTargetNow }) {
  const job = jobOf(target);
  const labels = labelsLine(target.target);
  const open = () => { if (job) window.open(job, "_blank", "noopener"); };
  return (
    <div class={`deploys-card${job ? " opens" : ""}`} role={job ? "link" : undefined} tabIndex={job ? 0 : undefined}
      title={job ? "Open the deploy’s job" : undefined} onClick={open}
      onKeyDown={(e) => { if (e.key === "Enter" && e.target === e.currentTarget) open(); }}>
      {labels && <span class="quiet deploys-labels">{labels}</span>}
      {target.live.length === 0 && <span class="quiet">{noLive}</span>}
      {target.live.map((l, i) => <Live key={l.deploy.ref ?? l.deploy.id} live={l} first={i === 0} />)}
      {target.next.map((n) => <span key={n.deploy.ref ?? n.deploy.id} class="quiet deploys-next">{nextWords(n)}</span>)}
    </div>
  );
}

function Live({ live, first }: { live: DeployOnTarget; first: boolean }) {
  const words = versionWords(live.deploy.version);
  const share = shareWords(live.share);
  const release = live.release;
  return (
    <>
      <span class="deploys-version">
        {release
          ? <a href="#" class="strong" title="Open the release’s page"
            onClick={(e) => { e.preventDefault(); e.stopPropagation(); go({ nav: "work", section: "release", item: release }); }}>{words}</a>
          : <span class="strong">{words}</span>}
        {live.deploy.rollback ? <span class="deploys-chip rollback">Rollback</span> : first && <span class="deploys-chip live">Live</span>}
      </span>
      {share && <span class="deploys-share"><span class="bar"><span style={{ width: `${live.share ?? 100}%` }} /></span>{share}</span>}
      {live.since !== undefined && <span class="deploys-since">{sinceWords(live.since)}</span>}
    </>
  );
}
