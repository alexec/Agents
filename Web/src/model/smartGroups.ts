// Which smart groups at the top of the sidebar are on (#846): Pinned, Needs You, Working and
// Unread; with nothing kept, Working and Unread are off (#979). The person's, kept on their Mac
// with the other display choices (#1033, SidebarSmartRow.offDefaultsKey): the groups turned
// off, by name, comma-separated, so a new group starts on.
import { computed } from "@preact/signals";
import { preferenceKeys, setPreferences, stringPreference } from "./preferences";
import { smartRows, type SmartRow } from "./sidebar";

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

/** The groups on, from the person's choice on their Mac (#1033). */
export const smartGroupsOn = computed<ReadonlySet<SmartRow>>(() =>
  smartRowsOn(stringPreference(preferenceKeys.smartGroupsOff)));

/** The person turns one group on or off: drawn at once, and kept on their Mac. */
export function setSmartGroup(row: SmartRow, isOn: boolean): void {
  const on = new Set(smartGroupsOn.peek());
  if (isOn) on.add(row);
  else on.delete(row);
  // "" too: every group on is a choice, not the first state (#979).
  setPreferences({ [preferenceKeys.smartGroupsOff]: smartRowsOff(on) });
}
