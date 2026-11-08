// A machine's row in the Machines section (#3974), as the window's MachineRow (#3973): its dot, what
// its menu and swipes do, and what Delete and Remove ask first. A machine a provider made can start,
// stop and be deleted; a registered one can only be removed; This Mac has neither.
import type { ControlMachine } from "../protocol/generated";
import { addMachineWords } from "./addMachine";

/** The dot's colour: green online, amber and turning while it changes, grey and hollow stopped, red offline or failed. */
export type MachineDot = "online" | "busy" | "stopped" | "offline" | "attention";

export function machineDot(host: ControlMachine, online: boolean, starting: boolean): MachineDot {
  if (starting || host.state === "starting" || host.state === "stopping") return "busy";
  if (host.state === "needsUpdate") return "attention";
  if (online) return "online";
  if (host.state === "stopped") return "stopped";
  return "offline";
}

export interface MachineActions {
  start: boolean;
  stop: boolean;
  /** Delete…: the provider deletes it. */
  delete: boolean;
  /** Remove…: Agents forgets it; the computer stays. */
  remove: boolean;
}

/** What a row offers, in its menu and its swipes. */
export function machineActions(host: ControlMachine, macID: string): MachineActions {
  if (host.id === macID) return { start: false, stop: false, delete: false, remove: false };
  const ws = host.workspace;
  const changing = host.state === "starting" || host.state === "stopping";
  return {
    start: !!ws && ws.canStart && !changing && host.state !== "online" && host.state !== "needsUpdate",
    stop: !!ws && ws.canStop && !changing && (host.state === "online" || host.state === "needsUpdate"),
    delete: !!ws,
    remove: !ws,
  };
}

/** The swipe to the right: Start or Stop; to the left: Delete or Remove, which ask first. */
export function machineSwipes(actions: MachineActions): { leading: "start" | "stop" | null; trailing: "delete" | "remove" | null } {
  return {
    leading: actions.start ? "start" : actions.stop ? "stop" : null,
    trailing: actions.delete ? "delete" : actions.remove ? "remove" : null,
  };
}

/** How far a finger goes across a row before the swipe is taken, in CSS pixels. */
export const swipeDistance = 72;

/** Delete's question: it always asks, and says how many sessions stop. */
export function deleteQuestion(host: ControlMachine, sessions: number): string {
  const at = host.workspace?.providerName ? `${host.workspace.providerName} deletes` : "Its provider deletes";
  const stop = sessions === 0 ? "" : ` ${sessions === 1 ? "1 session" : `${sessions} sessions`} on it ${sessions === 1 ? "stops" : "stop"}.`;
  return `Delete ${host.name}? ${at} this machine and its disk.${stop}`;
}

/** Remove's question, as Settings ▸ Machines asked it. */
export function removeQuestion(host: ControlMachine): string {
  return `${addMachineWords.removeTitle(host.name)} ${addMachineWords.removeNote}`;
}

/** The rows New Machine is making: the names that have not joined as a machine yet. */
export function makingRows(making: readonly string[], hosts: readonly { name: string }[]): string[] {
  return making.filter((name) => !hosts.some((h) => h.name === name));
}
