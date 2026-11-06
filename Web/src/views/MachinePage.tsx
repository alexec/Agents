// Machines ▸ <machine> (#3626): one machine's page, the place to go for its status, as the window's MachinePage.
// Its CPU and memory now, every disk its agents write to with the level the disk-low strip uses, and its processes
// (#3453). Read with machine/usage when it opens and every few seconds while it is open and the tab is seen.
import { useEffect, useState } from "preact/hooks";
import type { Store } from "../model/store";
import { hostAnswers, hostHas } from "../model/capabilities";
import { diskLine, freeWords, levelWords } from "../model/disk";
import { machineCPUWords, machineMemoryWords } from "../model/processes";
import { Capability } from "../protocol/capabilities.generated";
import type { MachineUsageState } from "../protocol/generated";
import { go } from "../route";
import { MachineProcesses } from "./settings/Processes";
import { chooseSettingsMachine } from "./settings/SettingsMachine";

export const disksFooter = "Each disk its agents write to. Low and almost full are the lines the disk-low warning uses.";

export function MachinePage({ store, host }: { store: Store; host: string }) {
  const hosts = store.hosts.value;
  const machine = hosts.find((h) => h.id === host);
  const answers = machine !== undefined && hostAnswers(machine.state);
  const asks = answers && hostHas(hosts, host, Capability.machineUsage1);
  const name = machine?.name ?? "This machine";
  const [usage, setUsage] = useState<MachineUsageState | null>(null);
  const [failure, setFailure] = useState<string | null>(null);
  useEffect(() => {
    if (!asks) return;
    let gone = false;
    const read = () => {
      if (document.visibilityState !== "visible") return;
      store.link.call("machine/usage", {}, host).then(
        (s) => { if (!gone) { setUsage(s); setFailure(null); } },
        () => { if (!gone) setFailure(`${name} can’t be asked how it is doing now.`); });
    };
    read();
    const timer = setInterval(read, 3_000);
    return () => { gone = true; clearInterval(timer); };
  }, [store, host, asks]);

  if (!machine) return <p class="hint">No machine by that name here now.</p>;
  return (
    <>
      <div class="setting">
        <span>{answers ? "Online" : <span class="failure">Offline</span>}</span>
        <button type="button" title={`${name}’s sleep, backups and desktop control, in Settings`}
          onClick={() => { chooseSettingsMachine(host); go({ nav: "settings" }); }}>Settings…</button>
      </div>
      {!answers ? <p class="hint">{name} is offline, so it can’t say how it is doing now.</p>
        : !asks ? <p class="hint">Update Agents on {name} to see its CPU, memory and disks here.</p>
        : (
          <>
            <section aria-labelledby="machine-usage">
              <h3 class="section-head" id="machine-usage">Usage</h3>
              {!usage && <p class="hint">{failure ?? "Loading…"}</p>}
              {usage && (
                <>
                  <div class="setting"><span>CPU</span><span>{machineCPUWords(usage.machine)}</span></div>
                  <div class="setting"><span>Memory</span><span>{machineMemoryWords(usage.machine)}</span></div>
                  {failure && <p class="hint">{failure}</p>}
                </>
              )}
            </section>
            {usage && (
              <section aria-labelledby="machine-disks">
                <h3 class="section-head" id="machine-disks">Disks</h3>
                {usage.disks.length === 0 && <p class="hint">No disk looked at yet. {name} looks every minute.</p>}
                {usage.disks.map((disk) => (
                  <div class="setting" key={disk.reading.mount} title={disk.level === "ok" ? disk.reading.mount : diskLine(disk)}>
                    <span>{disk.reading.volume} <span class="faint small">{disk.reading.mount}</span></span>
                    <span>
                      {freeWords(disk)}{" "}
                      <span class={disk.level === "critical" ? "failure" : disk.level === "low" ? "tinted" : "faint"}>
                        {levelWords(disk.level)}</span>
                    </span>
                  </div>
                ))}
                <p class="hint">{disksFooter}</p>
              </section>
            )}
          </>
        )}
      {answers && hostHas(hosts, host, Capability.processes1) && (
        <MachineProcesses store={store} host={host} name={name} showsTotals={false} />
      )}
    </>
  );
}
