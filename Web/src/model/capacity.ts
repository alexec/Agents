// A machine's capacity in words (#4582), as AgentsKitCore's CapacityWords says it on the window's page: the load
// and the level in the summary, a line that warns at near and full, and the starts that wait. The level and its
// signals come from machine/usage (#4578).
import type { CapacityLevel, MachineUsage, ResourceState } from "../protocol/generated";
import { oneDecimal } from "./disk";

/** "Load 2.4 per core", in the summary. */
export function loadWords(perCore: number): string {
  return `Load ${oneDecimal(perCore)} per core`;
}

/** "Near capacity" or "At capacity"; null at ok, where the summary says nothing of it. */
export function levelWords(level: CapacityLevel | undefined): string | null {
  return level === "near" ? "Near capacity" : level === "full" ? "At capacity" : null;
}

/** The class for the level's tint: attention at near, failure at full. */
export function levelClass(level: CapacityLevel | undefined): string {
  return level === "full" ? "failure" : level === "near" ? "warning" : "";
}

/** The warning at near and full: "This Mac is near capacity: load 2.4 per core." null at ok. machine.busy says the same. */
export function warningWords(usage: MachineUsage, name: string): string | null {
  const words = usage.capacity === "near" ? "near capacity" : usage.capacity === "full" ? "at capacity" : null;
  return words ? `${name} is ${words}: ${signalWords(usage)}.` : null;
}

/** What put it there, as machine.busy names it: the signal over the level's line, the load when none is. */
export function signalWords(usage: MachineUsage): string {
  const load = usage.loadPerCore ?? 0;
  const swap = usage.swapUsedPercent ?? 0;
  const pressure = `memory pressure ${usage.memoryPressure ?? "unknown"}`;
  if (usage.capacity === "full") {
    if (usage.memoryPressure === "critical") return pressure;
    if (swap > 50 && load <= 2.5) return `swap ${Math.round(swap)}% used`;
  } else if (usage.memoryPressure === "warn" && load <= 1.5) {
    return pressure;
  }
  return `load ${oneDecimal(load)} per core`;
}

/** Every signal, for the summary's tooltip; null before the first look. */
export function detailWords(usage: MachineUsage): string | null {
  if (usage.loadPerCore === undefined || usage.loadPerCore === null) return null;
  const parts = [`${loadWords(usage.loadPerCore)} over 1 minute`
    + (usage.loadPerCore5 !== undefined && usage.loadPerCore5 !== null ? `, ${oneDecimal(usage.loadPerCore5)} over 5` : "")];
  if (usage.memoryPressure) parts.push(`Memory pressure ${usage.memoryPressure}`);
  if (usage.swapUsedPercent !== undefined && usage.swapUsedPercent !== null) parts.push(`Swap ${Math.round(usage.swapUsedPercent)}% used`);
  return parts.join(" · ");
}

/** "2 starts queued": the sessions on the machine that wait for a place (#4377). null at none. */
export function queuedWords(count: number): string | null {
  return count === 0 ? null : `${count} ${count === 1 ? "start" : "starts"} queued`;
}

/** "1 lease in line for the machine": the leases whose lines wait for the machine, not a holder (#4748). null at none. */
export function leasesInLineWords(count: number): string | null {
  return count === 0 ? null : `${count} ${count === 1 ? "lease" : "leases"} in line for the machine`;
}

/** How many wait in lines that wait for the machine, from the lease snapshot (#4748). */
export function leasesInLine(resources: readonly ResourceState[]): number {
  return resources.filter((r) => r.capacityWait).reduce((n, r) => n + r.line.length, 0);
}

/** A queued start the machine holds, at the foot of its chat (#4748): "◷ In line to start · this Mac is near capacity". */
export function startLineWords(words: string): string {
  return `\u25F7 In line to start \u00B7 ${words}`;
}

/** A resource's line on the machine's page when it waits for the machine (#4748). */
export function heldForCapacityWords(words: string): string {
  return `Held for capacity: ${words}`;
}
