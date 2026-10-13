// Which smart groups at the top of the sidebar are on (#846): Pinned, Needs You, Working and
// Unread, all on until one is turned off. Kept in this browser's localStorage as the window and
// the Remote keep it in their own defaults (SidebarSmartRow.offDefaultsKey): the groups turned
// off, by name, comma-separated, so a new group starts on. It is this browser's alone, as its
// text size is (#750).
import { signal } from "@preact/signals";
import { allSmartRows, smartRows, type SmartRow } from "./sidebar";

const storageKey = "agents.sidebarSmartGroupsOff";

/** The groups on, from what is kept: a name that is not a group's is passed over. */
export function smartRowsOn(off: string | null | undefined): ReadonlySet<SmartRow> {
  const names = new Set((off ?? "").split(","));
  return new Set(smartRows.filter((row) => !names.has(row)));
}

/** What is kept for the groups on: those off, in the sidebar's order, or "" with every one on. */
export function smartRowsOff(on: ReadonlySet<SmartRow>): string {
  return smartRows.filter((row) => !on.has(row)).join(",");
}

// Through window, so a test without a page reads nothing (Node warns on a bare localStorage).
const storage = globalThis.window?.localStorage;

function read(): ReadonlySet<SmartRow> {
  try {
    return smartRowsOn(storage?.getItem(storageKey));
  } catch {
    return allSmartRows;
  }
}

/** The groups on in this browser. */
export const smartGroupsOn = signal<ReadonlySet<SmartRow>>(read());

/** The person turns one group on or off: kept, and drawn at once. */
export function setSmartGroup(row: SmartRow, isOn: boolean): void {
  const on = new Set(smartGroupsOn.peek());
  if (isOn) on.add(row);
  else on.delete(row);
  smartGroupsOn.value = on;
  const off = smartRowsOff(on);
  try {
    if (off === "") storage?.removeItem(storageKey);
    else storage?.setItem(storageKey, off);
  } catch {
    // A browser that keeps nothing (private, full) still draws the choice for this visit.
  }
}
