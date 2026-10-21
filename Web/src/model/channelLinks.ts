// The link card's and Settings ▸ Channels' words (#1762, spec 736 US7, FR-037), as the window's and
// the Remote's (AgentsKitCore's ChannelLinkWords): a channel identity acts as a person only once
// that person approves the link. A request that names nobody goes to the admins, who send it on.
import type { ChannelLink, ChannelLinkRequest } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

export const title = "Channels";

const named: Record<string, string> = { slack: "Slack", discord: "Discord", teams: "Teams", whatsapp: "WhatsApp", email: "Email" };

/** A channel's name as people say it: Slack, Discord; an unknown one as it is sent. */
export function channelName(channel: string): string {
  return named[channel] ?? channel.charAt(0).toUpperCase() + channel.slice(1);
}

/** "Slack user @sam", or "the email address sam@example.com". */
export function who(channel: string, identity: string, name?: string | undefined): string {
  if (channel === "email") return `the email address ${identity}`;
  return `${channelName(channel)} user ${name || identity}`;
}

const capital = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

/** The card's question: "Link Slack user @sam to you?", or for an admin "… is not linked to anyone." */
export function ask(request: ChannelLinkRequest): string {
  const sender = who(request.channel, request.identity, request.name);
  return request.for ? `Link ${sender} to you?` : `${capital(sender)} is not linked to anyone.`;
}

/** The card's second line: the identity, when the name hid it, and the email the channel gave. */
export function detail(request: ChannelLinkRequest): string | null {
  if (request.channel === "email") return null;
  const parts: string[] = [];
  if (request.name && request.name !== request.identity) parts.push(request.identity);
  if (request.email) parts.push(request.email);
  return parts.length ? parts.join(" · ") : null;
}

/** Under the buttons: what they do. */
export function explanation(request: ChannelLinkRequest): string {
  return request.for
    ? "Approve lets its messages start work as you. Deny ignores it for a day."
    : "Send asks that person to approve it. Only they can link it to themselves.";
}

/** A link's line in Settings ▸ Channels: "Slack user @sam". */
export function linkTitle(link: ChannelLink): string {
  return capital(who(link.channel, link.identity, link.name));
}

/** "T1/U42 · linked to Sam": whose it is, for an admin who sees everyone's. */
export function linkDetail(link: ChannelLink, you: string | undefined): string {
  const parts: string[] = [];
  if (link.channel !== "email" && link.name && link.name !== link.identity) parts.push(link.identity);
  parts.push(link.user === you ? "linked to you" : `linked to ${link.userName || link.user}`);
  return parts.join(" · ");
}

export function removeTitle(link: ChannelLink): string {
  return `Unlink ${who(link.channel, link.identity, link.name)}?`;
}

export const removeMessage = "Its messages start nothing until it is linked again.";
export const none = "No channel identity is linked.";
export const foot = "A message from Slack, email or another channel starts work only once its person links it here. Email also needs a DKIM pass for its address.";

/** A request said again replaces the one before it; a new one goes at the end. */
export function withRequest(list: readonly ChannelLinkRequest[], request: ChannelLinkRequest): ChannelLinkRequest[] {
  const at = list.findIndex((r) => r.request === request.request);
  if (at < 0) return [...list, request];
  const out = [...list];
  out[at] = request;
  return out;
}

/** A request decided, sent on or answered goes. */
export function withoutRequest(list: readonly ChannelLinkRequest[], request: string): ChannelLinkRequest[] {
  return list.filter((r) => r.request !== request);
}

/** The requests not yet expired at `now`. */
export function liveRequests(list: readonly ChannelLinkRequest[], now: Date = new Date()): ChannelLinkRequest[] {
  return list.filter((r) => fromWireDate(r.expires).getTime() > now.getTime());
}
