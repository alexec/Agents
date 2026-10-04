// Presence and the tab's title (071 FR-021, FR-022, research R11).
//
// The page reports presence as the Mac window does: active while it is visible and has focus,
// with the session open, on every change of either (half a second settled; a session opened at
// once) and on every connection. It takes no notices, so it never says whether it may show one. The title is
// `(N) Agents` when N sessions need the person, counted as the window counts its Dock badge.
import { effect } from "@preact/signals";
import type { Store } from "./model/store";

const settle = 500;

/**
 * Sessions wanting a look across live projects (needsPersonCount): Needs you, Blocked and unread.
 * Each project's count is worked out once per change to that project's agents (#170).
 */
export function needsPersonCount(store: Store): number {
  let total = 0;
  for (const [host, projects] of Object.entries(store.projects.value)) {
    for (const project of projects) {
      if (project.project.archivedAt !== undefined) continue;
      // Needs you, Blocked and unread finishes, as the Dock badge counts (#70).
      total += store.projectView(host, project.project.folder).attention;
    }
  }
  return total;
}

export function titleFor(count: number): string {
  return count > 0 ? `(${count}) Agents` : "Agents";
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
      if (host.state !== "online") continue;
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
    document.title = titleFor(needsPersonCount(store));
  });
}
