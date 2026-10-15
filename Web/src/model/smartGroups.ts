// Which smart groups at the top of the sidebar are on (#846): Pinned, Needs You, Working and
// Unread; with nothing kept, Working and Unread are off (#979). Kept in this browser's localStorage as the window and
// the Remote keep it in their own defaults (SidebarSmartRow.offDefaultsKey): the groups turned
// off, by name, comma-separated, so a new group starts on. It is this browser's alone, as its
// text size is (#750).
import { signal } from "@preact/signals";
import { smartRows, type SmartRow } from "./sidebar";

const storageKey = "agents.sidebarSmartGroupsOff";

/** What a browser with nothing kept reads (#979), as SidebarSmartRow.offAtFirst: Working and
 *  Unread off. One that keeps a choice, "" (every group on) too, keeps it. */
export const smartRowsOffAtFirst = "working,unread";

/** The groups on, from what is kept: a name that is not a group's is passed over. */
export function smartRowsOn(off: string | null | undefined): ReadonlySet<SmartRow> {
  const names = new Set((off ?? smartRowsOffAtFirst).split(","));
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
    return smartRowsOn(null);
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
  try {
    // "" too: every group on is a choice, not the first state (#979).
    storage?.setItem(storageKey, smartRowsOff(on));
  } catch {
    // A browser that keeps nothing (private, full) still draws the choice for this visit.
  }
}
