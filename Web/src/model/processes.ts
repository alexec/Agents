// A machine's processes (#3453): the words its page says, as the window's ProcessWords says them.
import type { MachineUsage, ProcessUsage } from "../protocol/generated";

/** A process's CPU, of one core: more than 100% on several. */
export function cpuWords(percent: number): string {
  if (percent < 0.05) return "0%";
  return percent < 10 ? `${percent.toFixed(1)}%` : `${Math.round(percent)}%`;
}

/** Resident memory, in the units Activity Monitor uses (1 GB is 1024 MB). */
export function memoryWords(bytes: number): string {
  const units = ["bytes", "KB", "MB", "GB", "TB"];
  let n = bytes;
  let unit = 0;
  while (n >= 1024 && unit < units.length - 1) {
    n /= 1024;
    unit++;
  }
  if (unit === 0) return `${n} bytes`;
  return `${n < 10 ? n.toFixed(1) : Math.round(n)} ${units[unit]}`;
}

export function machineCPUWords(machine: MachineUsage): string {
  return `${cpuWords(machine.cpuPercent)} of ${machine.cpuCount} ${machine.cpuCount === 1 ? "core" : "cores"}`;
}

export function machineMemoryWords(machine: MachineUsage): string {
  return `${memoryWords(machine.memoryUsed)} of ${memoryWords(machine.memoryTotal)}`;
}

/** Whether a row is the top of a session's processes (its runtime or a terminal), not a child of one: only
 * that row names the session. */
export function isSessionsOwn(process: ProcessUsage, all: readonly ProcessUsage[]): boolean {
  if (!process.agentId) return false;
  return all.find((p) => p.pid === process.parent)?.agentId !== process.agentId;
}

export const processesFooter = "Agents’ own processes only. Stop a session to stop its processes.";
