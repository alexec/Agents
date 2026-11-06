// Machines ▸ <machine> (#3626): one machine's page, the place to go for its status, as the window's MachinePage.
// Its CPU and memory now, every disk its agents write to with the level the disk-low strip uses, its worktrees, a
// section per folder (#3627), its runtimes and resources (#3629), and its processes (#3453). Read with machine/usage when it opens and every few seconds while it is open and the tab is seen.
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
import { WorktreesList } from "./Worktrees";
import { Resources } from "./Resources";
import { RuntimeSignInDialog } from "./RuntimeSignInDialog";
import { machineRuntimeLine, offersMachineSignIn, signInOnTheMac } from "../model/runtimes";
import type { RuntimeStatus } from "../protocol/generated";
import { forCleanup, pageLine, tally, worktreesIntro } from "../model/worktrees";

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
      {answers && <MachineWorktrees store={store} host={host} />}
      {answers && <MachineRuntimes store={store} host={host} name={name} />}
      {answers && <Resources store={store} host={host} />}
      {answers && hostHas(hosts, host, Capability.processes1) && (
        <MachineProcesses store={store} host={host} name={name} showsTotals={false} />
      )}
    </>
  );
}

/** The machine's worktrees (#3627): how much they hold, Refresh, and a section per folder. */
function MachineWorktrees({ store, host }: { store: Store; host: string }) {
  const groups = forCleanup(store.worktreeLists.value[host] ?? [], store.worktreeSizes.value[host]);
  return (
    <section aria-labelledby="machine-worktrees">
      <h3 class="section-head" id="machine-worktrees">Worktrees</h3>
      <div class="setting">
        <span>{pageLine(tally(groups.flatMap((g) => g.worktrees)))}</span>
        <button type="button" title="List the worktrees again" onClick={() => void store.loadWorktrees(host)}>Refresh</button>
      </div>
      <p class="hint">{worktreesIntro}</p>
      <WorktreesList store={store} host={host} />
    </section>
  );
}

/** The runtimes installed on the machine (#3629): each with whether it is there and signed in, and Sign In… on a
 * server's Claude or Codex (#3349). A server installs its runtimes when it is set up, and the daemon takes an install
 * only from the Mac, so there is no Install here. Accounts and allowances are the person's: Machines ▸ Runtimes. */
function MachineRuntimes({ store, host, name }: { store: Store; host: string; name: string }) {
  const [signingIn, setSigningIn] = useState<RuntimeStatus | null>(null);
  const runtimes = store.runtimes.value[host];
  const signs = store.has(host, Capability.runtimesSignIn1);
  return (
    <section class="machine-runtimes" aria-labelledby="machine-runtimes">
      <h3 class="section-head" id="machine-runtimes">Runtimes</h3>
      {!runtimes ? <p class="hint">Loading…</p> : runtimes.length === 0 ? <p class="hint">No runtimes known yet.</p> : (
        <ul>
          {runtimes.map((status) => (
            <li key={status.runtime.id}>
              <p><span class="strong">{status.runtime.name}</span>{" "}<span class="quiet small">{machineRuntimeLine(status)}</span></p>
              {offersMachineSignIn(status) && signs && (
                <button type="button" onClick={() => setSigningIn(status)}>Sign In…</button>
              )}
              {"needsSignIn" in status.availability && store.isMac(host) && <p class="quiet small">{signInOnTheMac}</p>}
            </li>
          ))}
        </ul>
      )}
      <p class="hint">What agents can start on here. Your accounts and allowances are in Machines ▸ Runtimes.</p>
      {signingIn && (
        <RuntimeSignInDialog store={store} host={host} runtimeID={signingIn.runtime.id} runtimeName={signingIn.runtime.name}
          machine={name} close={() => setSigningIn(null)} />
      )}
    </section>
  );
}
