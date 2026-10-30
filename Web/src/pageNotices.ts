// The page's own notification for what an agent told the person (#2860), until Web Push (#1486):
// only while the page is open, allowed, and in front. A notice the host sends to the "mac"
// surface goes to whichever window or page the person is at; the page in front is where they
// are. A click opens the chat at the notice's line, lit a moment. Taken back as the host
// withdraws it (its chat opened, or it went elsewhere).
import { signal } from "@preact/signals";
import type { AttentionNotification } from "./protocol/generated";
import type { Store } from "./model/store";
import { go } from "./route";
import { focusedEntry } from "./model/focus";

type Permission = "default" | "granted" | "denied" | "unsupported";

function permissionNow(): Permission {
  return typeof Notification === "undefined" ? "unsupported" : Notification.permission;
}

/** Whether this browser lets the page post notifications, for Settings ▸ Notifications. */
export const pagePermission = signal<Permission>(permissionNow());

/** Asked from a press in Settings, since a browser asks only on one. */
export async function allowPageNotices(): Promise<void> {
  if (typeof Notification === "undefined") return;
  pagePermission.value = await Notification.requestPermission();
}

/** What the page says of itself in Settings ▸ Notifications. */
export function pagePermissionText(permission: Permission): string {
  switch (permission) {
    case "granted":
      return "This page shows what agents tell you while it is open and in front.";
    case "denied":
      return "This browser blocks notifications from this page. Allow them in the browser's site settings.";
    case "unsupported":
      return "This browser cannot show notifications.";
    default:
      return "Allow notifications to see what agents tell you while this page is open and in front.";
  }
}

/** The notice's line, when this change posts one here; undefined when it posts nothing. */
export function noticeToPost(change: AttentionNotification, permission: Permission, inFront: boolean): string | undefined {
  if (!("notice" in change.needID) || change.need?.kind !== "notice" || !change.alert) return undefined;
  if (!change.to || !("mac" in change.to) || permission !== "granted" || !inFront) return undefined;
  return change.needID.notice;
}

export function startPageNotices(store: Store): void {
  const posted = new Map<string, Notification>();
  store.link.onNotification((method, params, host) => {
    if (method !== "attention/changed" || !host) return;
    const change = params as AttentionNotification;
    if (!("notice" in change.needID)) return;
    const line = change.needID.notice;
    // Over, or gone elsewhere: taken back.
    if (!change.need || !change.to || !("mac" in change.to)) {
      posted.get(line)?.close();
      posted.delete(line);
      return;
    }
    pagePermission.value = permissionNow();
    if (posted.has(line) || noticeToPost(change, pagePermission.value, document.visibilityState === "visible" && document.hasFocus()) === undefined) return;
    const { headline, agentID } = change.need;
    const shown = new Notification(headline.h2 || headline.h1, { body: headline.h3, tag: `notice:${line}` });
    posted.set(line, shown);
    shown.onclose = () => posted.delete(line);
    shown.onclick = () => {
      shown.close();
      window.focus();
      const agent = agentID ? store.agent(host, agentID) : undefined;
      if (!agent) return;
      focusedEntry.value = line;
      go({ host, folder: agent.worktree?.folder || agent.cwd, session: agent.id });
    };
  });
}
