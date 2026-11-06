// Which machine Settings' per-machine panes speak to (#3368): Agents ▸ Policy, Agent Runtimes and the
// ~/.agents editors. With a Mac they are the Mac's, as on the window. A control plane with no Mac
// names the machines it has, and the person chooses one; with none yet, the panes say so.
import type { ControlMachine } from "../protocol/generated";
import { hostAnswers } from "./capabilities";

export const machineLabel = "Machine";
export const noMachineYet = "No machine has joined this control plane yet. Add one in Settings ▸ Machines.";

/** The machines a pane can speak to: the Mac alone when there is one, else each machine that answers. */
export function settingsMachines(hosts: readonly ControlMachine[], macID: string): ControlMachine[] {
  const mac = hosts.find((h) => h.id === macID);
  if (mac) return [mac];
  return hosts.filter((h) => hostAnswers(h.state));
}

/** The machine in use: the one chosen while it is still listed, else the home host, else the first. */
export function settingsMachine(machines: readonly ControlMachine[], chosen: string | null,
                                home: string | undefined): ControlMachine | undefined {
  return machines.find((h) => h.id === chosen) ?? machines.find((h) => h.id === home) ?? machines[0];
}

/** At the top of a ~/.agents editor on a machine that is not a Mac: whose files they are. */
export const machineOnly = (name: string) => `${name}'s`;

/** Under machineOnly: with no Mac, nothing sends these files on to the other machines. */
export const machineKeepsItsOwn = (name: string) =>
  `Each machine keeps its own ~/.agents. These files are on ${name} only.`;
