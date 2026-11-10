// Settings ▸ Control plane ▸ Overview (#4252) on the page this Mac serves, as the window's: Serve Agents to browsers
// on this Mac, with Try Again when it can't, and This Mac's control plane with Restart. Listed in ./sections.ts.
import { useEffect, useState } from "preact/hooks";
import { canTryAgain, isOff, overviewWords as words, runningLine, serveLine } from "../../model/controlOverview";
import { describe } from "../../model/errors";
import type { Store } from "../../model/store";

export function ControlOverviewSection({ store, down }: { store: Store; down: boolean }) {
  const [busy, setBusy] = useState<"restart" | "serve" | "retry" | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const plane = store.plane.value;
  const web = plane?.web;
  const run = (step: "restart" | "serve" | "retry", work: () => Promise<void>) => {
    setBusy(step);
    setProblem(null);
    work().catch((error) => setProblem(describe(error))).finally(() => setBusy(null));
  };
  // Restarting… from the press until the page has gone and connected again.
  const [restarting, setRestarting] = useState<"asked" | "gone" | null>(null);
  useEffect(() => {
    if (restarting === "asked" && down) setRestarting("gone");
    if (restarting === "gone" && !down) setRestarting(null);
    // A page that never saw it go says Restart again after a while.
    if (restarting !== "asked") return;
    const timer = setTimeout(() => setRestarting(null), 15_000);
    return () => clearTimeout(timer);
  }, [restarting, down]);
  return (
    <section aria-labelledby="settings-control-overview">
      <h3 class="section-head" id="settings-control-overview">Overview</h3>
      {web && (
        <>
          <label class="setting">
            <span>{words.serve}</span>
            <input type="checkbox" role="switch" checked={!isOff(web)} disabled={down || busy !== null}
              onChange={(e) => {
                const on = e.currentTarget.checked;
                run("serve", () => store.setServeWeb(on));
              }} />
          </label>
          <p class={`hint${canTryAgain(web) ? " failure" : ""}`}>
            {serveLine(web)}{isOff(web) && ` ${words.offHere}`}
          </p>
          {canTryAgain(web) && (
            <button type="button" disabled={down || busy !== null} onClick={() => run("retry", () => store.retryWeb())}>
              {words.tryAgain}
            </button>
          )}
        </>
      )}
      <div class="setting">
        <span>
          {words.thisMac}
          <span class="hint"> · {runningLine(plane?.version, plane?.startedAt)}</span>
        </span>
        <button type="button" disabled={down || busy !== null || restarting !== null}
          onClick={() => { setRestarting("asked"); run("restart", () => store.restartControl().catch((error) => { setRestarting(null); throw error; })); }}>
          {restarting !== null ? words.restarting : words.restart}
        </button>
      </div>
      <p class="hint">{words.restartHint}</p>
      {problem && <p class="hint failure">{problem}</p>}
    </section>
  );
}
