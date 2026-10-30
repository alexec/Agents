// Presence and the tab's title (071 FR-021, FR-022, research R11).
//
// The page reports presence as the Mac window does: active while it is visible and has focus,
// with the session open, on every change of either (half a second settled; a session opened at
// once) and on every connection. It never says whether it may show a notice: only what agents tell the
// person shows here, while the page is in front (pageNotices.ts, #2860). The title is
// `(N) Agents` when N sessions need the person, counted as the window counts its Dock badge.
import { effect } from "@preact/signals";
import type { Store } from "./model/store";
import { alone } from "./route";
import { faviconFor, iconMood, type MoodCounts } from "./model/iconMood";
import { hostAnswers } from "./model/capabilities";

const settle = 500;

/**
 * Sessions that need the person across live folders (needsPersonCount): Needs you and Blocked, not unread (#1565).
 * Each folder's count is worked out once per change to that folder's agents (#170).
 */
export function needsPersonCount(store: Store): number {
  let total = 0;
  for (const [host, folders] of Object.entries(store.folders.value)) {
    for (const folder of folders) {
      if (folder.folder.archivedAt !== undefined) continue;
      // Needs you and Blocked, as the Dock badge counts (#1565).
      total += store.folderView(host, folder.folder.folder).attention;
    }
  }
  return total;
}

/** Each live folder's view, for the favicon's mood (#1317). */
function* liveViews(store: Store): Generator<MoodCounts> {
  for (const [host, folders] of Object.entries(store.folders.value)) {
    for (const folder of folders) {
      if (folder.folder.archivedAt === undefined) yield store.folderView(host, folder.folder.folder);
    }
  }
}

/** The tab's title: Agents, or the folder a tab holds alone (#1089), after how many need the person. */
export function titleFor(count: number, folder?: string): string {
  const name = folder ?? "Agents";
  return count > 0 ? `(${count}) ${name}` : name;
}

export function startPresence(store: Store): void {
  let timer: ReturnType<typeof setTimeout> | undefined;
  let open = false;
  const report = () => {
    if (!open) return;
    const shown = store.watching.value;
    const active = document.visibilityState === "visible" && document.hasFocus();
    // Every online host hears whether the person is here; the open session's host hears which
    // it is, which is where its entries come from (#203). Another host hears it shows nothing.
    for (const host of store.hosts.value) {
      if (!hostAnswers(host.state)) continue;
      const session = shown?.host === host.id ? shown.session as never : undefined;
      void store.link.call("presence/report", { active, ...(session ? { watching: session, showing: session } : {}) }, host.id)
        .catch(() => {});
    }
  };
  const soon = () => {
    clearTimeout(timer);
    timer = setTimeout(report, settle);
  };
  document.addEventListener("visibilitychange", soon);
  addEventListener("focus", soon);
  addEventListener("blur", soon);
  store.link.onState((state) => {
    open = state.kind === "open";
    if (open) soon();
  });
  // Hosts arriving after a connection.
  effect(() => {
    void store.hosts.value;
    soon();
  });
  // A session opened or closed: said at once, before its transcript is read, so nothing it says
  // meanwhile goes only to the pages already showing it (#203).
  effect(() => {
    void store.watching.value;
    clearTimeout(timer);
    report();
  });
  effect(() => {
    const held = alone.value;
    document.title = titleFor(needsPersonCount(store), held && decodeURIComponent(held.folder.replace(/\/+$/, "").split("/").pop() ?? ""));
  });
  // The Blob's mood on the favicon (#1317), changed only when the mood does.
  effect(() => {
    const href = faviconFor[iconMood(liveViews(store))];
    const icon = document.querySelector<HTMLLinkElement>("link[rel=icon]");
    if (icon && icon.getAttribute("href") !== href) icon.setAttribute("href", href);
  });
}
