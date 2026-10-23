// Whether the chat draws the agent's thoughts (#1725), as ChatThoughts.swift keeps the window's
// and the Remote's choice. Off unless turned on: most people do not want to read the agent's
// thinking. This browser's own choice, kept in localStorage, as the icon's mood is.

import { signal } from "@preact/signals";
import { omittingThoughts, type Item } from "./turns";

const key = "showsThoughts";
// Through window, so a test without a page reads nothing (Node warns on a bare localStorage).
const storage = globalThis.window?.localStorage;

/** Show Thoughts, in the chat's ··· menu (#2383), as View ▸ Show Thoughts on the Mac. */
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

/** The chat menu's item (#2383), in ChatThoughts.menuTitle's and menuHelp's words. */
export function thoughtsItem(shows: boolean): { label: string; title: string } {
  return {
    label: shows ? "Hide Thoughts" : "Show Thoughts",
    title: "Show each of the agent's thoughts as one folded line in the chat, or leave them out",
  };
}
