// Whether the chat draws the agent's thoughts (#1725), as ChatThoughts.swift keeps the window's
// and the Remote's choice. Off unless turned on: most people do not want to read the agent's
// thinking. This browser's own choice, kept in localStorage, as the icon's mood is.

import { signal } from "@preact/signals";
import { omittingThoughts, type Item } from "./turns";

const key = "showsThoughts";
// Through window, so a test without a page reads nothing (Node warns on a bare localStorage).
const storage = globalThis.window?.localStorage;

/** Settings ▸ Appearance ▸ Show thoughts. */
export const showsThoughts = signal(storage?.getItem(key) === "true");

export function setShowsThoughts(on: boolean): void {
  showsThoughts.value = on;
  storage?.setItem(key, String(on));
}

/** Each page with its thoughts left off, the same array while the page is, so a memo'd turn is not drawn again. */
const withoutThoughts = new WeakMap<readonly Item[], readonly Item[]>();

/** `items` as the chat draws them: with the thoughts, or with them left off. */
export function shownItems(items: readonly Item[], shows: boolean = showsThoughts.value): readonly Item[] {
  if (shows) return items;
  const kept = withoutThoughts.get(items);
  if (kept) return kept;
  const shown = omittingThoughts(items);
  withoutThoughts.set(items, shown);
  return shown;
}

/** The words under the switch, as the window's and the Remote's. */
export const thoughtsFooter = "On, the chat shows each of the agent's thoughts as one folded line. Off, they are not shown.";
