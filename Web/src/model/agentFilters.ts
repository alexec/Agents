// Agents' filters (#2141): which machine's folders and which sessions the sidebar shows. Kept for the
// tab (sessionStorage), so a reload keeps them and another tab starts with every session.
import { signal } from "@preact/signals";
import type { Agent } from "../protocol/generated";
import { sessionMark } from "./sidebar";

export type StateFilter = "any" | "needsYou" | "working" | "done";
export const stateFilters: readonly StateFilter[] = ["any", "needsYou", "working", "done"];
export const stateFilterTitle: Record<StateFilter, string> = { any: "Any state", needsYou: "Needs You", working: "Working", done: "Done" };

const storage = globalThis.window?.sessionStorage;
const machineKey = "agentsFilterMachine";
const stateKey = "agentsFilterState";

function read(key: string): string | null {
  try { return storage?.getItem(key) ?? null; } catch { return null; }
}

function write(key: string, value: string | null): void {
  try { if (value === null) storage?.removeItem(key); else storage?.setItem(key, value); } catch { /* private mode: for this page only */ }
}

/** The machine whose folders show, by id; null for every machine. */
export const machineFilter = signal<string | null>(read(machineKey));
export const stateFilter = signal<StateFilter>((stateFilters as readonly string[]).includes(read(stateKey) ?? "") ? read(stateKey) as StateFilter : "any");

export function setMachineFilter(id: string | null): void {
  machineFilter.value = id;
  write(machineKey, id);
}

export function setStateFilter(state: StateFilter): void {
  stateFilter.value = state;
  write(stateKey, state === "any" ? null : state);
}

/** Whether a session shows under a state filter. */
export function keptByState(agent: Agent, state: StateFilter): boolean {
  if (state === "any") return true;
  const mark = sessionMark(agent);
  switch (state) {
    case "needsYou": return mark === "needsYou";
    case "working": return mark === "working" || mark === "tool" || mark === "queued" || mark === "waiting";
    case "done": return mark === "done" || mark === "asksToArchive" || mark === "paused";
  }
}
