// The sidebar's search field (#3898): held here, not in the sidebar, so a label's chip in a row or
// in the chat can ask it for that label, as LabelFilter does in the window and on the Remote.
import { signal } from "@preact/signals";
import { asksFor, parseQuery, toggleLabel } from "./labels";

export const sidebarSearch = signal("");

/** The field's placeholder, which names `label:` so it can be found (SessionSearchWords.prompt). */
export const searchPrompt = "Search, or label:name";

export const filterHint = "Shows only the sessions with this label, or all of them again.";

/** A click on a label's chip: the search asks for it, or, when it already does, no longer does. */
export function filterByLabel(label: string): void {
  sidebarSearch.value = toggleLabel(sidebarSearch.value, label);
}

export function filtersBy(label: string): boolean {
  return asksFor(parseQuery(sidebarSearch.value), label);
}
