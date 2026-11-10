// Messages (#4344), as the window's MessagesView: the conversations of every messaging connector that
// follows the messaging contract, on every machine, from messages/conversations, in one list, the newest
// first, with Source and Unread filters; a conversation's page from messages/read, with a reply field
// (messages/reply, #4345) when its connector can send. Its text is outside content: drawn as plain text,
// never as markup.
import { signal, useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { MessagingMessage } from "../protocol/generated";
import type { Store } from "../model/store";
import { Capability } from "../protocol/capabilities.generated";
import { describe } from "../model/errors";
import { hostAnswers } from "../model/capabilities";
import { channelName } from "../model/channelLinks";
import { ago } from "../model/connectorSetup";
import {
  inThread, leaveThread, mergeConversations, messagesProblems, messagesSources, noConnector, noConnectorIn, noConversations, noMachine,
  noMessages, noUnread, outside, replyInThread, replyLabel, replyPlaceholder, replyText, send, senderName, sending, sentAs, setUp,
  sourceGlyph, unreadWords, type HostConversations, type MessagesRow,
} from "../model/messages";
import { go } from "../route";

/** The list's state, for the tab: a conversation's page goes back to it as it was left. */
const lists = signal<HostConversations[] | null>(null);
const source = signal("");
const unreadOnly = signal(false);
const asked = signal(0);

const messagesHosts = (store: Store) => store.hosts.value.filter((h) => hostAnswers(h.state) && store.has(h.id, Capability.messages1));

async function readLists(store: Store, hosts: { id: string; name: string }[], cursors?: Map<string, string>): Promise<HostConversations[]> {
  return Promise.all(hosts.map(async (h): Promise<HostConversations> => {
    try {
      const cursor = cursors?.get(h.id);
      const got = await store.link.call("messages/conversations",
        { limit: 50, ...unreadOnly.value ? { unread: true } : {}, ...cursor ? { cursor } : {} }, h.id);
      return { host: h.id, name: h.name, conversations: got.conversations, cursor: got.cursor, errors: got.errors ?? [] };
    } catch (e) {
      return { host: h.id, name: h.name, conversations: [], errors: [], problem: describe(e) };
    }
  }));
}

const hostNames = (store: Store) => messagesHosts(store).map((h) => ({ id: h.id, name: h.name || h.id }));

/** Reads the lists when the machines or the Unread filter change, or on Refresh. */
function useLists(store: Store) {
  const hostKey = messagesHosts(store).map((h) => h.id).join(",");
  useEffect(() => {
    let current = true;
    lists.value = null;
    void readLists(store, hostNames(store)).then((l) => { if (current) lists.value = l; });
    return () => { current = false; };
  }, [hostKey, asked.value, unreadOnly.value]);
}

export function MessagesList({ store }: { store: Store }) {
  useLists(store);
  const more = useSignal(false);
  const hosts = messagesHosts(store);
  const l = lists.value;
  const rows = l ? mergeConversations(l, source.value) : [];
  const firstFolder = Object.entries(store.folders.value).flatMap(([host, fs]) => fs.map((f) => ({ host, folder: f.folder.folder })))[0];
  const loadMore = async () => {
    if (!l || more.value) return;
    more.value = true;
    const cursors = new Map(l.filter((h) => h.cursor).map((h) => [h.host, h.cursor!]));
    const got = await readLists(store, hostNames(store).filter((h) => cursors.has(h.id)), cursors);
    lists.value = l.map((h) => {
      const next = got.find((g) => g.host === h.host);
      return next ? { ...next, conversations: [...h.conversations, ...next.conversations] } : h;
    });
    more.value = false;
  };

  return (
    <div class="work-list messages-list">
      <div class="work-filters" role="group" aria-label="Filters">
        <label>Source <select value={source.value} onChange={(e) => { source.value = (e.target as HTMLSelectElement).value; }}>
          <option value="">All</option>
          {messagesSources(l ?? []).map((s) => <option key={s} value={s}>{channelName(s)}</option>)}
        </select></label>
        <label><input type="checkbox" checked={unreadOnly.value}
          onChange={(e) => { unreadOnly.value = (e.target as HTMLInputElement).checked; }} /> Unread</label>
        <button type="button" class="link" onClick={() => { asked.value++; }}>Refresh</button>
      </div>
      {hosts.length === 0 ? <p class="hint">{noMachine}</p>
        : l === null ? <p class="hint">Loading…</p>
        : noConnectorIn(l) && !unreadOnly.value ? (
          <div class="messages-empty">
            <p class="hint">{noConnector}</p>
            {firstFolder && <button type="button" class="link" title="The folder's Connectors, with its Messaging slot"
              onClick={() => go({ host: firstFolder.host, folder: firstFolder.folder, mcp: true })}>{setUp}</button>}
          </div>
        ) : <>
          {messagesProblems(l).map((p) => <p key={p} class="hint">{p}</p>)}
          {rows.length === 0 ? <p class="hint">{unreadOnly.value ? noUnread : noConversations}</p> : (
            <ul class="work-rows">
              {rows.map((r) => <ConversationRow key={r.key} row={r} />)}
            </ul>
          )}
          {l.some((h) => h.cursor) && (
            <button type="button" class="link" disabled={more.value} onClick={() => { void loadMore(); }}>{more.value ? "Loading…" : "More"}</button>
          )}
        </>}
    </div>
  );
}

function ConversationRow({ row }: { row: MessagesRow }) {
  const c = row.item.conversation;
  const unread = unreadWords(c);
  return (
    <li data-key={row.key}>
      <button type="button" class={`work-row messages-row${unread ? " unread" : ""}`}
        onClick={() => go({ nav: "messages", section: "messages", item: row.key })}>
        <span class="work-row-head">
          <span class="messages-source" title={channelName(c.source)} aria-label={channelName(c.source)}>{sourceGlyph(c.source)}</span>
          <span class="work-title messages-title">{c.title}</span>
          {unread && <span class="messages-unread small">{unread}</span>}
          {c.lastActivity && <span class="quiet small docs-updated">{ago(new Date(c.lastActivity))}</span>}
        </span>
      </button>
    </li>
  );
}

/** A conversation's page: its messages, the newest first, each with its sender, time, text and a link to the
 * original; older pages with Older; under them the reply field, when the connector can send. Found by its key
 * in the list, read again when the tab was opened on it. */
export function ConversationPage({ store, conversationKey }: { store: Store; conversationKey: string }) {
  useLists(store);
  const messages = useSignal<MessagingMessage[] | null>(null);
  const cursor = useSignal<string | undefined>(undefined);
  const problem = useSignal<string | null>(null);
  const loading = useSignal(false);
  const draft = useSignal("");
  const thread = useSignal<string | undefined>(undefined);
  const busy = useSignal(false);
  const sendProblem = useSignal<string | null>(null);
  const l = lists.value;
  const row = l ? mergeConversations(l).find((r) => r.key === conversationKey) : undefined;
  const replyAs = row?.item.replyAs;
  const reply = async () => {
    const text = replyText(draft.value);
    if (!row || !text || busy.value) return;
    busy.value = true;
    sendProblem.value = null;
    try {
      const got = await store.link.call("messages/reply", {
        server: row.item.server, folder: row.item.folder, conversation: row.item.conversation.id, text,
        ...thread.value ? { thread: thread.value } : {},
      }, row.host);
      messages.value = [got.message, ...messages.value ?? []];
      draft.value = "";
    } catch (e) {
      sendProblem.value = describe(e);
    }
    busy.value = false;
  };
  const read = async (older: boolean) => {
    if (!row) return;
    loading.value = true;
    try {
      const got = await store.link.call("messages/read", {
        server: row.item.server, folder: row.item.folder, conversation: row.item.conversation.id, limit: 50,
        ...older && cursor.value ? { cursor: cursor.value } : {},
      }, row.host);
      messages.value = [...older ? messages.value ?? [] : [], ...got.messages];
      cursor.value = got.cursor;
    } catch (e) {
      problem.value = describe(e);
    }
    loading.value = false;
  };
  useEffect(() => { messages.value = null; problem.value = null; void read(false); }, [row?.key, row?.host]);

  if (l === null) return <p class="hint">Loading…</p>;
  if (!row) return <p class="hint">This conversation is not in the list any more. <button type="button" class="link" onClick={() => go({ nav: "messages" })}>Messages</button></p>;
  const c = row.item.conversation;
  return (
    <article class="work-page messages-page">
      <div class="work-page-bar">
        <button type="button" title="Back" aria-label="Back" onClick={() => history.back()}>‹</button>
        <button type="button" title="Forward" aria-label="Forward" onClick={() => history.forward()}>›</button>
        <button type="button" class="link" onClick={() => go({ nav: "messages" })}>All messages</button>
      </div>
      <header class="work-page-head">
        <h2><span class="work-title">{c.title}</span></h2>
        <p class="quiet small">
          {sourceGlyph(c.source)} {channelName(c.source)} ▸ {row.item.server}
          {c.link && <> · <a href={c.link} target="_blank" rel="noopener noreferrer">Open in {channelName(c.source)}</a></>}
        </p>
      </header>
      <p class="hint">{outside}</p>
      {problem.value ? <p class="hint">{problem.value}</p>
        : messages.value === null ? <p class="hint">Loading…</p>
        : messages.value.length === 0 ? <p class="hint">{noMessages}</p>
        : (
          <ul class="messages-rows">
            {messages.value.map((m) => (
              <li key={m.id} class="messages-message">
                <div class="messages-head">
                  <strong title={m.sender.identity}>{senderName(m.sender)}</strong>
                  <span class="quiet small">{new Date(m.time).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })}</span>
                  {replyAs && m.thread && <button type="button" class="link small messages-thread"
                    onClick={() => { thread.value = m.thread; }}>{replyInThread}</button>}
                  {m.link && <a class="small messages-original" href={m.link} target="_blank" rel="noopener noreferrer">Original</a>}
                </div>
                <p class="messages-text">{m.text}</p>
              </li>
            ))}
          </ul>
        )}
      {cursor.value && !problem.value && (
        <button type="button" class="link" disabled={loading.value} onClick={() => { void read(true); }}>{loading.value ? "Loading…" : "Older"}</button>
      )}
      {replyAs && !problem.value && messages.value !== null && (
        <form class="messages-reply" onSubmit={(e) => { e.preventDefault(); void reply(); }}>
          {thread.value && <p class="quiet small">↩ {inThread} · <button type="button" class="link" onClick={() => { thread.value = undefined; }}>{leaveThread}</button></p>}
          <div class="messages-reply-row">
            <textarea rows={2} aria-label={replyLabel} placeholder={replyPlaceholder} value={draft.value} disabled={busy.value}
              onInput={(e) => { draft.value = (e.target as HTMLTextAreaElement).value; }}
              onKeyDown={(e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); void reply(); } }} />
            <button type="submit" title="Send the reply (⌘↩)" disabled={busy.value || !replyText(draft.value)}>{busy.value ? sending : send}</button>
          </div>
          <p class="quiet small">{sentAs(replyAs)}</p>
          {sendProblem.value && <p class="hint">{sendProblem.value}</p>}
        </form>
      )}
    </article>
  );
}
