// The page's own notification for what an agent told the person (#2860): only while the page is
// open, allowed, and in front. A notice the host sends to the "mac" surface goes to whichever
// window or page the person is at; the page in front is where they are. A click opens the chat at
// the notice's line, lit a moment. Taken back as the host withdraws it (its chat opened, or it
// went elsewhere).
//
// And Web Push (#1486): once allowed, the page subscribes this browser with the control plane's
// VAPID key and gives the subscription over its own session, as the Remote gives its APNs token.
// The control plane pushes to it when the ladder picks it (no iPhone gets the need); sw.ts shows
// it, also with the page closed. The page closes those when it comes into view.
import { signal } from "@preact/signals";
import type { AttentionNotification } from "./protocol/generated";
import type { Store } from "./model/store";
import type { Link } from "./wire/link";
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
  if (link) await subscribeWebPush(link);
}

/** Web Push in this browser: on; none from this control plane; not without the Home Screen (iOS); or not here. */
export type WebPushState = "off" | "on" | "none" | "homeScreen" | "unsupported";

export const webPush = signal<WebPushState>("off");

let link: Link | undefined;

/** An iPhone or iPad, where Safari gives Web Push only to a page added to the Home Screen. */
function onIOS(): boolean {
  return /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
}

/** Whether this browser can take Web Push at all. */
export function webPushHere(hasWorker: boolean, hasPush: boolean, iOS: boolean): WebPushState {
  if (hasWorker && hasPush) return "off";
  return iOS ? "homeScreen" : "unsupported";
}

/** base64url without padding, as the control plane reads a key. */
export function base64url(bytes: ArrayBuffer | null): string {
  if (!bytes) return "";
  return btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function decode(key: string): Uint8Array<ArrayBuffer> {
  const plain = atob(key.replace(/-/g, "+").replace(/_/g, "/"));
  const bytes = new Uint8Array(new ArrayBuffer(plain.length));
  for (let i = 0; i < plain.length; i++) bytes[i] = plain.charCodeAt(i);
  return bytes;
}

interface TrustedTypes {
  createPolicy(name: string, rules: { createScriptURL(url: string): string }): { createScriptURL(url: string): unknown };
}

/** The worker's address, through the one Trusted Types policy the page's policy names (agents-sw). */
function workerURL(): string {
  const types = (globalThis as { trustedTypes?: TrustedTypes }).trustedTypes;
  if (!types) return "/sw.js";
  const policy = types.createPolicy("agents-sw", {
    createScriptURL: (url) => {
      if (url !== "/sw.js") throw new TypeError("only the page's own worker");
      return url;
    },
  });
  return policy.createScriptURL("/sw.js") as string;
}

let registration: Promise<ServiceWorkerRegistration> | undefined;

/** Subscribes this browser, or takes its subscription away when notifications are not allowed. */
async function subscribeWebPush(to: Link): Promise<void> {
  const here = webPushHere("serviceWorker" in navigator, "PushManager" in globalThis, onIOS());
  if (here !== "off") {
    webPush.value = here;
    return;
  }
  try {
    registration ??= navigator.serviceWorker.register(workerURL(), { scope: "/" });
    const worker = await registration;
    const held = await worker.pushManager.getSubscription();
    if (permissionNow() !== "granted") {
      if (held) {
        await held.unsubscribe();
        await to.call("clients/setWebPush", {});
      }
      webPush.value = "off";
      return;
    }
    const { publicKey } = await to.call("clients/webPushKey", {});
    if (!publicKey) {
      webPush.value = "none";
      return;
    }
    let subscription = held;
    if (subscription && base64url(subscription.options.applicationServerKey) !== publicKey) {
      await subscription.unsubscribe();
      subscription = null;
    }
    subscription ??= await worker.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: decode(publicKey) });
    const keys = subscription.toJSON().keys ?? {};
    await to.call("clients/setWebPush", { endpoint: subscription.endpoint, ...(keys.p256dh ? { p256dh: keys.p256dh } : {}), ...(keys.auth ? { auth: keys.auth } : {}) });
    webPush.value = "on";
  } catch {
    webPush.value = "unsupported";
  }
}

/** Closes what Web Push showed: the person is at the page now, which shows what needs them. */
function closePushed(): void {
  if (!registration) return;
  void registration.then((worker) => worker.getNotifications()).then((shown) => {
    for (const notification of shown) notification.close();
  }, () => {});
}

/** What Settings says of Web Push in this browser; "" when there is nothing to say. */
export function webPushText(state: WebPushState): string {
  switch (state) {
    case "on":
      return "When no iPhone gets them, this browser shows what agents need from you, also with this page closed.";
    case "none":
      return "This control plane sends no Web Push, so this browser shows them only while this page is open.";
    case "homeScreen":
      return "On an iPhone or iPad, add this page to the Home Screen to get notifications.";
    default:
      return "";
  }
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
  link = store.link;
  store.link.onState((state) => {
    if (state.kind === "open" && permissionNow() !== "default") void subscribeWebPush(store.link);
  });
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") closePushed();
  });
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
