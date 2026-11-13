// The Messages page (#4344), as the window's (AgentsKitCore's MessagesList): every machine's conversations
// from messages/conversations in one list, each conversation once, the newest first, and its words; the
// reply field's too (#4345).
import type { ChannelSender, Event, MessagesConversation, MessagesError, MessagesMarkedAllRead, MessagingConversation } from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";
import { channelName } from "./channelLinks";
import { shortAgo } from "./statusSecrets";

/** One machine's answer, or why it gave none. */
export interface HostConversations {
  host: string;
  name: string;
  conversations: MessagesConversation[];
  cursor?: string | undefined;
  errors: MessagesError[];
  problem?: string | undefined;
}

/** One row: a conversation and the machine to read it on. */
export interface MessagesRow { host: string; item: MessagesConversation; key: string }

export const conversationKey = (c: MessagingConversation): string => `${c.source}:${c.id}`;

const time = (c: MessagingConversation): number | undefined => {
  const t = c.lastActivity ? Date.parse(c.lastActivity) : NaN;
  return Number.isNaN(t) ? undefined : t;
};

/** The machines' conversations in one list, each once (the first machine's: this Mac comes first), the newest
 * first; one with no time goes last. source keeps one service's. */
export function mergeConversations(lists: HostConversations[], source = ""): MessagesRow[] {
  const seen = new Set<string>();
  const rows: MessagesRow[] = [];
  for (const l of lists) {
    for (const item of l.conversations) {
      if (source && item.conversation.source !== source) continue;
      const key = conversationKey(item.conversation);
      if (seen.has(key)) continue;
      seen.add(key);
      rows.push({ host: l.host, item, key });
    }
  }
  return rows.map((r, i) => ({ r, i })).sort((a, b) => {
    const x = time(a.r.item.conversation), y = time(b.r.item.conversation);
    if (x !== undefined && y !== undefined && x !== y) return y - x;
    if (x !== undefined && y === undefined) return -1;
    if (x === undefined && y !== undefined) return 1;
    return a.i - b.i;
  }).map(({ r }) => r);
}

/** The services the lists have, for the Source filter, by name. */
export function messagesSources(lists: HostConversations[]): string[] {
  return [...new Set(lists.flatMap((l) => l.conversations.map((c) => c.conversation.source)))]
    .sort((a, b) => channelName(a).localeCompare(channelName(b)));
}

/** The lines that say what could not be read: a machine, or a connector on one. */
export function messagesProblems(lists: HostConversations[]): string[] {
  return lists.flatMap((l) => l.problem ? [`${l.name}: ${l.problem}`] : l.errors.map((e) => `${l.name} ▸ ${e.server}: ${e.message}`));
}

/** No machine has a messaging connector that follows the contract: no conversation and no error. */
export const noConnectorIn = (lists: HostConversations[]): boolean =>
  lists.every((l) => l.conversations.length === 0 && l.errors.length === 0 && !l.problem);

export const noMachine = "No machine reads messages yet. Update Agents on a machine to read its messaging connectors.";
export const noConnector = "No messaging connector yet. Add Slack, Email, Google Chat or WhatsApp in a folder's Connectors ▸ Messaging.";
export const setUp = "Open Connectors";
export const noConversations = "No conversations.";
export const noUnread = "No unread conversations.";
export const noMessages = "No messages.";
export const outside = "Outside content: these messages come from other people, through the connector.";

export const replyLabel = "Reply";
export const send = "Send";
export const sending = "Sending…";
export const replyPlaceholder = "Write a reply";
export const replyInThread = "Reply in thread";
export const inThread = "In a thread";
export const leaveThread = "Not in the thread";

/** Who the reply goes as, under the field (#4345). */
export const sentAs = (replyAs: string): string => `Sent as ${replyAs}, not as an agent.`;

/** The text of a reply to send: trimmed, or undefined when there is none. */
export const replyText = (draft: string): string | undefined => draft.trim() || undefined;

/** "3 unread", or undefined. */
export const unreadWords = (c: MessagingConversation): string | undefined => (c.unread ?? 0) > 0 ? `${c.unread} unread` : undefined;

/** The sender as people say it: a name, else the handle or address. */
export const senderName = (s: ChannelSender): string => s.name || s.identity;

/** A glyph for a service, beside its name for a screen reader. */
export function sourceGlyph(source: string): string {
  switch (source) {
    case "slack": return "#";
    case "email": return "✉";
    case "whatsapp": return "✆";
    default: return "💬";
  }
}

// The grey line at the head of Messages (#4934), as the window's sidebar row (MessagesList.statusLine).

/** The event a messaging connector raises for a message (Slack, Google Chat, WhatsApp). */
export const receivedEvent = "message.received";

/** The newest message.received and what came of it: "woke Fix login bug", "started triage", or "nothing woke". */
export interface LastConsequence { at: number; words: string }

/** The newest message.received in `events` (every machine's, in any order) and what it did: the session it woke, else
 * the workflow it started, else "nothing woke", the case a person looks into. Undefined when there is none. */
export function lastConsequence(events: readonly Event[]): LastConsequence | undefined {
  const latest = (e: Event) => fromWireDate(e.lastAt ?? e.at).getTime();
  const newest = events.filter((e) => e.name === receivedEvent).reduce<Event | undefined>((a, e) => (!a || latest(e) > latest(a) ? e : a), undefined);
  if (!newest) return undefined;
  const woke = newest.consequences.find((c) => "woke" in c);
  const fired = newest.consequences.find((c) => "fired" in c);
  const words = woke && "woke" in woke ? `woke ${woke.woke.title}`
    : fired && "fired" in fired ? `started ${fired.fired.workflowID}` : "nothing woke";
  return { at: latest(newest), words };
}

/** The unread messages of every machine's conversations, each conversation once; undefined when none gives a count. */
export function unreadTotal(lists: HostConversations[]): number | undefined {
  const counts = mergeConversations(lists).flatMap((r) => r.item.conversation.unread ?? []);
  return counts.length ? counts.reduce((a, b) => a + b, 0) : undefined;
}

/** "12 unread · woke Fix login bug 4 min ago". A count of 0 or none is left out; undefined when there is nothing to say. */
export function messagesStatusLine(unread: number | undefined, last: LastConsequence | undefined, now = Date.now()): string | undefined {
  const parts = [unread ? `${unread} unread` : null, last ? `${last.words} ${shortAgo(last.at, now)}` : null].filter((p): p is string => !!p);
  return parts.length ? parts.join(" · ") : undefined;
}

// Next and Mark All as Read (#5137), as the window's.

/** The row after `key` in `rows` (the list as it is filtered and sorted now); undefined at the end, or when `key` is not in it. */
export function nextRow(rows: MessagesRow[], key: string): MessagesRow | undefined {
  const at = rows.findIndex((r) => r.key === key);
  return at >= 0 ? rows[at + 1] : undefined;
}

/** The lists with the conversation `key` read on every machine that has it, or every conversation when `key` is absent.
 * A count the service never gave stays absent. */
export function markedRead(lists: HostConversations[], key?: string): HostConversations[] {
  return lists.map((l) => ({
    ...l,
    conversations: l.conversations.map((c) => (key === undefined || conversationKey(c.conversation) === key) && c.conversation.unread !== undefined
      ? { ...c, conversation: { ...c.conversation, unread: 0 } } : c),
  }));
}

/** Whether Mark All as Read has something to do: a loaded row is unread, or a page is still to come. */
export const hasUnread = (lists: HostConversations[]): boolean =>
  mergeConversations(lists).some((r) => (r.item.conversation.unread ?? 0) > 0) || lists.some((l) => !!l.cursor);

/** What Mark All as Read could not do: a machine, or a connector on one. */
export function markProblems(answers: { name: string; marked?: MessagesMarkedAllRead | undefined; problem?: string | undefined }[]): string[] {
  return answers.flatMap((a) => a.problem ? [`${a.name}: ${a.problem}`] : (a.marked?.errors ?? []).map((e) => `${a.name} ▸ ${e.server}: ${e.message}`));
}

export const nextConversation = "Next conversation";
export const nextHelp = "The next conversation in the list (⌥⌘↓)";
export const markAllRead = "Mark all as read";
export const markingAllRead = "Marking…";
export const markAllHelp = "Mark every conversation read, on each machine and service that keeps a read state";
