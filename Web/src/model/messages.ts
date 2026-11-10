// The Messages page (#4344), as the window's (AgentsKitCore's MessagesList): every machine's conversations
// from messages/conversations in one list, each conversation once, the newest first, and its words.
import type { ChannelSender, MessagesConversation, MessagesError, MessagingConversation } from "../protocol/generated";
import { channelName } from "./channelLinks";

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

export const messagesTitle = "Messages";
export const noMachine = "No machine reads messages yet. Update Agents on a machine to read its messaging connectors.";
export const noConnector = "No messaging connector yet. Add Slack, Email, Google Chat or WhatsApp in a folder's Connectors ▸ Messaging.";
export const setUp = "Open Connectors";
export const noConversations = "No conversations.";
export const noUnread = "No unread conversations.";
export const noMessages = "No messages.";
export const outside = "Outside content: these messages come from other people, through the connector.";

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
