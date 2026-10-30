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
import { DataTable } from "./DataTable";
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
          <DataTable id="live" label="Live Now" rows={shown.agents} rowKey={(a) => `${a.host} ${a.agent}`}
            order={{ column: "cost", dir: "desc" }} empty={noLive}
            rowClass={(a) => a.state === "waitingOnUser" ? "attention-row" : undefined} columns={[
              { id: "agent", title: "Agent", sort: (a) => runtimeName(a.runtime), cell: (a) => <>
                {runtimeName(a.runtime)} <span class="quiet small live-id">{liveShortID(a)}</span>
                {a.workflow && <span class="quiet small"> · {a.workflow}</span>}</> },
              { id: "whose", title: "Whose", sort: (a) => a.ownerName, cell: (a) => a.bot ? `${a.ownerName} (bot)` : a.ownerName },
              { id: "machine", title: "Machine", sort: (a) => a.hostName, cell: (a) => a.hostName },
              { id: "state", title: "State", sort: liveStateWords,
                cell: (a) => <span class={a.state === "waitingOnUser" ? "attention" : ""}>{liveStateWords(a)}</span> },
              { id: "since", title: "Running", first: "desc", sort: (a) => a.since,
                cell: (a) => <span class="quiet">{a.since === undefined ? "—" : `started ${ago(fromWireDate(a.since))}`}</span> },
              { id: "cost", title: "So far", num: true, first: "desc", sort: (a) => Object.values(a.costToDate ?? {}).reduce((x, y) => x + y, 0), cell: (a) => liveCostWords(a.costToDate) },
              { id: "stop", title: "", cell: (a) => (
                <button type="button" disabled={down || stopping.value.has(a.agent)} aria-label={liveStopLabel(a, runtimeName(a.runtime))}
                  onClick={() => { if (window.confirm(liveStopQuestion(a, runtimeName(a.runtime)))) void stop([a]); }}>Stop…</button>) },
            ]} />
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
