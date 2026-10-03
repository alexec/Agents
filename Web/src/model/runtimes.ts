// The order runtimes are listed in, as RuntimeCatalog.sortedByName (AgentsKitCore) has it (#154):
// alphabetical by the name shown, case-insensitive and as the person's language would, the id
// breaking a tie. A host on an older build still answers in its catalog's order.
import type { RuntimeStatus } from "../protocol/generated";

/** The runtime a new agent gets when nothing else says: RuntimeCatalog.defaultRuntime. */
export const defaultRuntimeID = "claude";

export function byName(a: { name: string; id: string }, b: { name: string; id: string }): number {
  return a.name.localeCompare(b.name, undefined, { sensitivity: "base", numeric: true })
    || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
}

export function sortedRuntimes(runtimes: RuntimeStatus[]): RuntimeStatus[] {
  return [...runtimes].sort((a, b) => byName(a.runtime, b.runtime));
}

/** With no recent agent to go by: the default when it can start, else the first in order. */
export function firstChoice(available: RuntimeStatus[]): string | undefined {
  return available.find((r) => r.runtime.id === defaultRuntimeID)?.runtime.id ?? available[0]?.runtime.id;
}
