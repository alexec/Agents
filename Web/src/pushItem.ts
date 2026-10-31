// What the service worker shows for one Web Push (#1486), apart from it so a test can read it.
import type { ControlPushItem } from "./protocol/generated";

/** The notification for one push: the need's words, or only that an agent needs the person. One a need. */
export function notificationFor(item: ControlPushItem): { title: string; options: NotificationOptions } {
  const headline = item.headline;
  const title = headline ? headline.h2 || headline.h1 || "Agents" : "Agents";
  const body = headline ? headline.h3 : "An agent needs you";
  return { title, options: { body, tag: `need:${JSON.stringify(item.needID)}`, silent: !item.alert, icon: "/assets/icon-192.png" } };
}
