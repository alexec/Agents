// Settings ▸ Machines ▸ Processes (#3453): what runs on a machine, as the window's MachineProcessesSection. Listed
// in ./sections.ts.
import { useEffect, useState } from "preact/hooks";
import type { Store } from "../../model/store";
import { hostAnswers, hostHas } from "../../model/capabilities";
import { cpuWords, isSessionsOwn, machineCPUWords, machineMemoryWords, memoryWords, processesFooter } from "../../model/processes";
import { Capability } from "../../protocol/capabilities.generated";
import type { ProcessesState, ProcessUsage } from "../../protocol/generated";
import { go } from "../../route";

/** One machine's processes, read when it opens and every few seconds while it is open and the tab is seen. Its
 * CPU and memory above them, but not on the machine's page (#3626), which says them in its own Usage. */
export function MachineProcesses({ store, host, name, showsTotals = true }: { store: Store; host: string; name: string; showsTotals?: boolean }) {
  const [state, setState] = useState<ProcessesState | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  useEffect(() => {
    let gone = false;
    const read = () => {
      if (document.visibilityState !== "visible") return;
      store.link.call("processes/list", {}, host).then(
        (s) => { if (!gone) { setState(s); setFailure(null); } },
        () => { if (!gone) setFailure(`${name} can’t be asked about its processes now.`); });
    };
    read();
    const timer = setInterval(read, 3_000);
    return () => { gone = true; clearInterval(timer); };
  }, [store, host]);
  const open = (process: ProcessUsage) => {
    const agent = (store.agents.value[host] ?? []).find((a) => a.id === process.agentId);
    if (agent) go({ host, folder: agent.worktree?.folder || agent.cwd, session: agent.id });
  };
  const id = `settings-processes-${host}`;
  return (
    <section aria-labelledby={id}>
      <h3 class="section-head" id={id}>Processes on {name}</h3>
      {!state && (failure ? <p class="hint">{failure}</p> : <p class="hint">Loading…</p>)}
      {state && (
        <>
          {showsTotals && <div class="setting"><span>CPU</span><span>{machineCPUWords(state.machine)}</span></div>}
          {showsTotals && <div class="setting"><span>Memory</span><span>{machineMemoryWords(state.machine)}</span></div>}
          {state.processes.map((process) => (
            <div class="setting" key={process.pid} title={`Process ${process.pid}`}>
              <span style={{ paddingLeft: `${Math.min(process.depth, 6) * 14}px` }}>
                {process.name}
                {process.depth === 0 && <span class="faint small"> Agents’ daemon</span>}
                {isSessionsOwn(process, state.processes) && (
                  <> <button type="button" class="link small" onClick={() => open(process)}>
                    {process.title ?? "Untitled session"}</button></>
                )}
              </span>
              <span class="faint small process-usage">{cpuWords(process.cpuPercent)} · {memoryWords(process.memory)}</span>
            </div>
          ))}
          {state.omitted > 0 && <p class="hint">And {state.omitted} more.</p>}
          {failure && <p class="hint">{failure}</p>}
        </>
      )}
      <p class="hint">{processesFooter}</p>
    </section>
  );
}

/** Processes (#3453): a row for each machine that answers now, opening what runs on it. */
export function ProcessesSection({ store }: { store: Store }) {
  const [open, setOpen] = useState<string | null>(null);
  const hosts = store.hosts.value;
  const machines = hosts.filter((h) => hostAnswers(h.state) && hostHas(hosts, h.id, Capability.processes1));
  if (machines.length === 0) return null;
  const shown = machines.find((h) => h.id === open);
  return (
    <>
      <section aria-labelledby="settings-processes">
        <h3 class="section-head" id="settings-processes">Processes</h3>
        {machines.map((host) => (
          <div class="setting" key={host.id}>
            <span>{host.name}</span>
            <button type="button" aria-expanded={open === host.id}
              onClick={() => setOpen(open === host.id ? null : host.id)}>{open === host.id ? "Hide" : "Processes…"}</button>
          </div>
        ))}
      </section>
      {shown && <MachineProcesses key={shown.id} store={store} host={shown.id} name={shown.name} />}
    </>
  );
}
