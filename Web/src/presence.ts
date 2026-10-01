// Presence and the tab's title (071 FR-021, FR-022, research R11).
//
// The page reports presence as the Mac window does: active while it is visible and has focus,
// with the session open, on every change of either (half a second settled) and on every
// connection. It takes no notices, so it never says whether it may show one. The title is
// `(N) Agents` when N sessions need the person, counted as the window counts its Dock badge.
import { effect } from "@preact/signals";
import type { Store } from "./model/store";
import { attentionCount } from "./model/groups";

const settle = 500;

/** Sessions wanting a look across live projects (needsPersonCount): Needs you, Blocked and unread. */
export function needsPersonCount(store: Store): number {
  let total = 0;
  for (const [host, projects] of Object.entries(store.projects.value)) {
    const agents = store.agents.value[host] ?? [];
    for (const project of projects) {
      if (project.project.archivedAt !== undefined) continue;
      // Needs you, Blocked and unread finishes, as the Dock badge counts (#70).
      total += attentionCount(agents, project.project.folder);
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
    const watching = store.watching.value?.session;
    const active = document.visibilityState === "visible" && document.hasFocus();
    // To the host whose session is open, else the first online one: presence is per client.
    const host = store.watching.value?.host ?? store.hosts.value.find((h) => h.state === "online")?.id;
    if (!host) return;
    void store.link.call("presence/report", { active, ...(watching ? { watching: watching as never } : {}) }, host)
      .catch(() => {});
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
  // A session opened or closed, or hosts arriving after a connection.
  effect(() => {
    void store.watching.value;
    void store.hosts.value;
    soon();
  });
  effect(() => {
    document.title = titleFor(needsPersonCount(store));
  });
}
