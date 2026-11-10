// What the service worker shows for one Web Push (#1486), apart from it so a test can read it.
import type { ControlPushItem } from "./protocol/generated";

/** The notification for one push: the need's words, or only that an agent needs the person. One a need; data.open is where a click goes. */
export function notificationFor(item: ControlPushItem): { title: string; options: NotificationOptions } {
  const headline = item.headline;
  const title = headline ? headline.h2 || headline.h1 || "Agents" : "Agents";
  const body = headline ? headline.h3 : "An agent needs you";
  // A machine's notice (#3682) opens the machines: the push does not say which host sent it.
  const open = "notice" in item.needID && item.needID.notice.startsWith("disk:") ? "/#/machines/machines" : "/";
  // The person's booking's holder asks (#4268): it stays until the person acts on it.
  const timely = item.timely === true;
  return { title, options: { body, tag: `need:${JSON.stringify(item.needID)}`, silent: !item.alert, requireInteraction: timely, icon: "/assets/icon-192.png", data: { open } } };
}
