// Machines ▸ <machine> (#3626): one machine's page, the place to go for its status, as the window's MachinePage.
// A summary first (#3743): its CPU, memory and worst disk on one line. Then the detail, most of it closed until the
// person opens it: the disk that matters with the others folded, a row per folder's worktrees (#3627), the runtimes
// installed there (#3629), resources only when one is declared or held, and its processes (#3453). Read with
// machine/usage when it opens and every few seconds while it is open and the tab is seen.
import { useEffect, useState } from "preact/hooks";
import type { Store } from "../model/store";
import { hostAnswers, hostHas } from "../model/capabilities";
import { diskLine, freeWords, headline, levelWords, summaryWords } from "../model/disk";
import { cpuWords, machineCPUWords, machineMemoryWords } from "../model/processes";
import { Capability } from "../protocol/capabilities.generated";
import type { DiskAlarm, MachineUsageState } from "../protocol/generated";
import { go } from "../route";
import { MachineProcesses } from "./settings/Processes";
import { chooseSettingsMachine } from "./settings/SettingsMachine";
import { WorktreesList } from "./Worktrees";
import { Resources } from "./Resources";
import { RuntimeSignInDialog } from "./RuntimeSignInDialog";
import { isInstalled, machineRuntimeLine, offersMachineSignIn, signInOnTheMac } from "../model/runtimes";
import type { RuntimeStatus } from "../protocol/generated";
import { forCleanup, pageLine, tally, worktreesIntro } from "../model/worktrees";

const disksHelp = "Each disk its agents write to. Low and almost full are the lines set in Folder Settings ▸ Disk Space.";

const levelClass = (disk: DiskAlarm) => disk.level === "critical" ? "failure" : disk.level === "low" ? "tinted" : "";

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
  // The disk the summary names and Disks shows open: the worst, or the folders' own; the others fold (#3743).
  const disks = usage?.disks ?? [];
  const top = headline(disks, (store.worktreeLists.value[host] ?? []).map((g) => decodeURIComponent(new URL(g.folder, "file:///").pathname)));
  const shownDisks = disks.filter((d) => d.level !== "ok" || d === top);
  const otherDisks = disks.filter((d) => !shownDisks.includes(d));
  const diskRow = (disk: DiskAlarm) => (
    <div class="setting" key={disk.reading.mount} title={disk.level === "ok" ? disk.reading.mount : `${disk.reading.mount}: ${diskLine(disk)}`}>
      <span>{disk.reading.volume}</span>
      <span>{freeWords(disk)} <span class={levelClass(disk) || "faint"}>{levelWords(disk.level)}</span></span>
    </div>
  );
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
            <section aria-labelledby="machine-summary">
              <h3 class="section-head visually-hidden" id="machine-summary">Summary</h3>
              {!usage && <p class="hint">{failure ?? "Loading…"}</p>}
              {usage && (
                <>
                  <div class="setting machine-summary" title={machineCPUWords(usage.machine)}>
                    <span>
                      CPU {cpuWords(usage.machine.cpuPercent)} · Memory {machineMemoryWords(usage.machine)}
                      {top && <> · <span class={levelClass(top)} title={top.level === "ok" ? top.reading.volume : diskLine(top)}>
                        {summaryWords(top)}</span></>}
                    </span>
                  </div>
                  {failure && <p class="hint">{failure}</p>}
                </>
              )}
            </section>
            {usage && (
              <section aria-labelledby="machine-disks">
                <h3 class="section-head" id="machine-disks" title={disksHelp}>Disks</h3>
                {usage.disks.length === 0 && <p class="hint">No disk looked at yet. {name} looks every minute.</p>}
                {shownDisks.map(diskRow)}
                {otherDisks.length > 0 && (
                  <details class="machine-fold">
                    <summary>Other disks ({otherDisks.length})</summary>
                    {otherDisks.map(diskRow)}
                  </details>
                )}
              </section>
            )}
          </>
        )}
      {answers && <MachineWorktrees store={store} host={host} />}
      {answers && <MachineRuntimes store={store} host={host} name={name} />}
      {answers && <Resources store={store} host={host} />}
      {answers && hostHas(hosts, host, Capability.processes1) && (
        <MachineProcesses store={store} host={host} name={name} showsTotals={false} folds />
      )}
    </>
  );
}

/** The machine's worktrees (#3627): how much they hold, Refresh, and a closed row per folder (#3743). */
function MachineWorktrees({ store, host }: { store: Store; host: string }) {
  const groups = forCleanup(store.worktreeLists.value[host] ?? [], store.worktreeSizes.value[host]);
  return (
    <section aria-labelledby="machine-worktrees">
      <h3 class="section-head" id="machine-worktrees" title={worktreesIntro}>Worktrees</h3>
      <div class="setting">
        <span>{pageLine(tally(groups.flatMap((g) => g.worktrees)))}</span>
        <button type="button" title="List the worktrees again" onClick={() => void store.loadWorktrees(host)}>Refresh</button>
      </div>
      <WorktreesList store={store} host={host} />
    </section>
  );
}

/** The runtimes installed on the machine (#3629), one line each: its version and whether it is signed in, and Sign In…
 * on a server's Claude or Codex (#3349). Only the installed ones (#3743): Status ▸ Runtimes lists every runtime. A server installs
 * its runtimes when it is set up, and the daemon takes an install only from the Mac, so there is no Install here.
 * Accounts and allowances are the person’s: Status ▸ Runtimes. */
function MachineRuntimes({ store, host, name }: { store: Store; host: string; name: string }) {
  const [signingIn, setSigningIn] = useState<RuntimeStatus | null>(null);
  const runtimes = store.runtimes.value[host]?.filter(isInstalled);
  const signs = store.has(host, Capability.runtimesSignIn1);
  return (
    <section class="machine-runtimes" aria-labelledby="machine-runtimes">
      <h3 class="section-head" id="machine-runtimes" title="What agents can start on here">Runtimes</h3>
      {!runtimes ? <p class="hint">Loading…</p> : runtimes.length === 0 ? <p class="hint">None installed here yet.</p> : (
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
      <p><button type="button" class="link small" onClick={() => go({ nav: "status", section: "runtimes" })}>
        Every runtime, your accounts and allowances, in Status</button></p>
      {signingIn && (
        <RuntimeSignInDialog store={store} host={host} runtimeID={signingIn.runtime.id} runtimeName={signingIn.runtime.name}
          machine={name} close={() => setSigningIn(null)} />
      )}
    </section>
  );
}
