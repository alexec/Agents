// Console ▸ Live Now (#2019, M9): every agent running now on every machine of the organisation,
// as each machine last listed it (console/live), the most costly first, with whose machine it is,
// its runtime, state, how long it has run and its cost so far. Stop ends one (console/stopAgent);
// Stop All on a machine ends each of its agents. The kill switch for everything is Policy's.
// Ids and numbers only; no agent's title or words: a short id tells two agents apart (#2435).
import { useEffect } from "preact/hooks";
import { useSignal } from "@preact/signals";
import type { Store } from "../model/store";
import type { LiveAgent, LiveBoard } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { ago } from "../model/connectorSetup";
import { failedWords, liveCostWords, liveFoot, liveMachines, liveShortID, liveStateWords, liveStopLabel, liveStopQuestion, liveSummary,
  noLive } from "../model/console";

export function LiveNowPage({ store, down, runtimeName }: { store: Store; down: boolean; runtimeName: (id: string) => string }) {
  const board = useSignal<LiveBoard | null>(null);
  const problem = useSignal<string | null>(null);
  const stopping = useSignal<Set<string>>(new Set());
  const load = async () => {
    try {
      board.value = await store.link.call("console/live", {});
      problem.value = null;
    } catch (error) {
      problem.value = failedWords(error);
    }
  };
  useEffect(() => { if (!down) void load(); }, [down]);
  useEffect(() => {
    const every = setInterval(() => { if (document.visibilityState === "visible" && !down) void load(); }, 15_000);
    return () => clearInterval(every);
  }, [down]);
  const stop = async (agents: readonly LiveAgent[]) => {
    stopping.value = new Set([...stopping.value, ...agents.map((a) => a.agent)]);
    const failed: string[] = [];
    for (const a of agents) {
      try {
        await store.link.call("console/stopAgent", { host: a.host, agent: a.agent });
      } catch (error) {
        failed.push(failedWords(error));
      }
    }
    problem.value = failed[0] ?? null;
    stopping.value = new Set([...stopping.value].filter((id) => !agents.some((a) => a.agent === id)));
    await load();
  };
  const shown = board.value;
  const machines = shown ? liveMachines(shown) : [];
  return (
    <div class="team-workflows">
      {problem.value && <p class="hint" role="alert">{problem.value}</p>}
      {!shown && !problem.value && <p class="hint">Loading…</p>}
      {shown && shown.agents.length === 0 && <p class="hint">{noLive}</p>}
      {shown && shown.agents.length > 0 && (
        <>
          <p class="quiet small">{liveSummary(shown)}</p>
          <table class="console-table">
            <thead><tr><th>Agent</th><th>Whose</th><th>State</th><th>Running</th><th class="num">So far</th><th /></tr></thead>
            <tbody>
              {shown.agents.map((a) => (
                <tr key={`${a.host} ${a.agent}`}>
                  <td>{runtimeName(a.runtime)} <span class="quiet small live-id">{liveShortID(a)}</span>
                    {a.workflow && <span class="quiet small"> · {a.workflow}</span>}</td>
                  <td>{a.ownerName}<span class="quiet small"> · {a.hostName}</span></td>
                  <td class={a.state === "waitingOnUser" ? "attention" : ""}>{liveStateWords(a)}</td>
                  <td class="quiet">{a.since === undefined ? "—" : `started ${ago(fromWireDate(a.since))}`}</td>
                  <td class="num">{liveCostWords(a.costToDate)}</td>
                  <td><button type="button" disabled={down || stopping.value.has(a.agent)} aria-label={liveStopLabel(a, runtimeName(a.runtime))}
                    onClick={() => { if (window.confirm(liveStopQuestion(a, runtimeName(a.runtime)))) void stop([a]); }}>Stop…</button></td>
                </tr>
              ))}
            </tbody>
          </table>
          {machines.some((m) => m.agents.length > 1) && (
            <ul class="request-list">
              {machines.filter((m) => m.agents.length > 1).map((m) => (
                <li key={m.host} class="request">
                  <span>{m.agents.length} agents on {m.hostName}<span class="quiet small"> · {m.ownerName}</span></span>
                  <span class="request-actions">
                    <button type="button" disabled={down} onClick={() => {
                      if (window.confirm(`Stop all ${m.agents.length} agents on ${m.hostName}? Each one stops now, as Stop… does, and its owner reads that an admin stopped it.`)) void stop(m.agents);
                    }}>Stop All on This Machine…</button>
                  </span>
                </li>
              ))}
            </ul>
          )}
        </>
      )}
      {shown && <p class="hint">{liveFoot}</p>}
    </div>
  );
}
