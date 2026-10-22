// Console ▸ Team Workflows (#1804, M6): each bot (#1761), its group, its machines and its spend
// today against its cap, the workflows it ran in the last 7 days, and the agents running on its
// machines now, each with Stop (bots/stopRun). Numbers and ids only; no agent's title or words.
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { TeamBotRun, TeamWorkflows } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { ago } from "../model/connectorSetup";
import { failedWords, machineWords, noBots, runsWords, spendWords, teamWorkflowsFoot } from "../model/console";

export function TeamWorkflowsPage({ store, down }: { store: Store; down: boolean }) {
  const board = useSignal<TeamWorkflows | null>(null);
  const problem = useSignal<string | null>(null);
  const load = async () => {
    try {
      board.value = await store.link.call("console/teamWorkflows", {});
      problem.value = null;
    } catch (error) {
      problem.value = failedWords(error);
    }
  };
  const changes = store.peopleChanges.value;
  useEffect(() => { if (!down) void load(); }, [down, changes, store.capped.value]);
  useEffect(() => {
    const every = setInterval(() => { if (document.visibilityState === "visible" && !down) void load(); }, 60_000);
    return () => clearInterval(every);
  }, [down]);
  const stop = async (run: TeamBotRun) => {
    try {
      await store.link.call("bots/stopRun", { host: run.host, agent: run.agent });
      problem.value = null;
    } catch (error) {
      problem.value = failedWords(error);
    }
    await load();
  };
  const shown = board.value;
  return (
    <div class="team-workflows">
      {problem.value && <p class="hint" role="alert">{problem.value}</p>}
      {!shown && !problem.value && <p class="hint">Loading…</p>}
      {shown && shown.bots.length === 0 && <p class="hint">{noBots}</p>}
      {shown?.bots.map((bot) => (
        <section key={bot.user} class="bot-card" aria-labelledby={`bot-${bot.user}`}>
          <h3 id={`bot-${bot.user}`}>
            {bot.name}
            {bot.groupName && <span class="quiet small"> · {bot.groupName}</span>}
          </h3>
          <p class="quiet small">{machineWords(bot)} · <span class={bot.capped ? "attention" : ""}>{spendWords(bot)}</span></p>
          {bot.workflows.length === 0 ? <p class="hint">No runs in the last 7 days.</p> : (
            <table class="console-table">
              <thead><tr><th>Workflow</th><th class="num">Last 7 days</th><th>Last run</th></tr></thead>
              <tbody>
                {bot.workflows.map((w) => (
                  <tr key={w.workflow}>
                    <td>{w.workflow}</td>
                    <td class="num">{runsWords(w.runs)}</td>
                    <td class="quiet">{w.lastRunAt === undefined ? "—" : ago(fromWireDate(w.lastRunAt))}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          {bot.live.length > 0 && (
            <ul class="request-list">
              {bot.live.map((run) => (
                <li key={`${run.host} ${run.agent}`} class="request">
                  <span>
                    Running {run.workflow ?? "an agent"} on {run.hostName}
                    {run.since !== undefined && <span class="quiet small"> · started {ago(fromWireDate(run.since))}</span>}
                  </span>
                  <span class="request-actions"><button type="button" disabled={down} onClick={() => void stop(run)}>Stop</button></span>
                </li>
              ))}
            </ul>
          )}
        </section>
      ))}
      {shown && <p class="hint">{teamWorkflowsFoot}</p>}
    </div>
  );
}
