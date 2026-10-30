// The page's service worker (#1486): it shows what the control plane sends this browser by Web Push
// when the ladder picks it, also with the page closed. The push is sealed to this browser's keys
// (RFC 8291), so the push service reads none of it; the browser opens it before this sees it. Every
// push shows a notification: a browser takes away a subscription whose pushes show none. The page
// closes these when it comes into view (pageNotices.ts). A click opens the page, or brings it forward.
import type { ControlPushItem } from "./protocol/generated";
import { notificationFor } from "./pushItem";

// What this uses of a service worker's scope; the DOM library has none of it.
interface PushEvent extends Event {
  readonly data: { json(): unknown } | null;
  waitUntil(promise: Promise<unknown>): void;
}
interface NotificationEvent extends Event {
  readonly notification: Notification;
  waitUntil(promise: Promise<unknown>): void;
}
interface WindowClient {
  readonly url: string;
  focus(): Promise<WindowClient>;
}
interface Scope {
  readonly registration: ServiceWorkerRegistration;
  readonly clients: {
    matchAll(options: { type: "window"; includeUncontrolled: boolean }): Promise<readonly WindowClient[]>;
    openWindow(url: string): Promise<WindowClient | null>;
    claim(): Promise<void>;
  };
  skipWaiting(): Promise<void>;
  addEventListener(type: "push", listener: (event: PushEvent) => void): void;
  addEventListener(type: "notificationclick", listener: (event: NotificationEvent) => void): void;
  addEventListener(type: "install" | "activate", listener: (event: PushEvent) => void): void;
}

const scope = self as unknown as Scope;

scope.addEventListener("install", (event) => event.waitUntil(scope.skipWaiting()));
scope.addEventListener("activate", (event) => event.waitUntil(scope.clients.claim()));

scope.addEventListener("push", (event) => {
  let item: ControlPushItem | undefined;
  try {
    item = event.data?.json() as ControlPushItem | undefined;
  } catch {
    item = undefined;
  }
  const { title, options } = item ? notificationFor(item) : { title: "Agents", options: { body: "An agent needs you" } };
  event.waitUntil(scope.registration.showNotification(title, options));
});

scope.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil((async () => {
    const pages = await scope.clients.matchAll({ type: "window", includeUncontrolled: true });
    const page = pages[0];
    if (page) await page.focus();
    else await scope.clients.openWindow("/");
  })());
});
