---
diataxis: reference
devices: [mac, web, server]
description: The tools, input and structuredContent that a messaging MCP server gives, so that the Messages page can read Mail, Slack, Google Chat, WhatsApp and any other server that follows the contract.
---

# Messaging contract

A messaging MCP server that follows this contract gives the same tools, with the same input
and the same `structuredContent`, whatever service it reads. The daemon calls these tools
over MCP, and the **Messages** page (#4337) shows the conversations of every such server in
one list. The servers that Agents makes (Email, Slack, Google Chat, WhatsApp) follow it, and
a third-party server (Discord, Telegram, Teams) can follow it too, with no change in Agents.

Why messaging is a contract over MCP, and the forges are not, is in
[Connector levels](../explanation/connector-levels.md#a-contract-or-in-process).

The shapes are in `Packages/Wire/daemon.schema.json` (#1135), so the Go servers, the daemon
and the clients use one type: `MessagingListRequest`, `MessagingConversations`,
`MessagingConversation`, `MessagingConversationKind`, `MessagingReadRequest`,
`MessagingMessages`, `MessagingMessage` and `MessagingReplyRequest`.

## How a server says that it follows the contract

Each tool of the contract has this key in its `_meta`, in `tools/list`:

```json
{ "_meta": { "agents/messaging": 1 } }
```

The number is the contract's version. This page is version 1. A server follows the contract
when `list_conversations` and `read_messages` both have the key. `reply` has it only when the
server can send. The Messaging slot (#1787) reads `tools/list` already, so it knows which
connectors the page can read, with no extra call.

A later version adds only optional input and optional fields. A change that is not
compatible takes the next number, and the daemon reads each version that it knows.

## The tools

| Tool | Input | `structuredContent` | Annotations |
|---|---|---|---|
| `list_conversations` | `MessagingListRequest` | `MessagingConversations` | `readOnlyHint` |
| `read_messages` | `MessagingReadRequest` | `MessagingMessages` | `readOnlyHint` |
| `reply` (later, #4337) | `MessagingReplyRequest` | the sent message, a `MessagingMessage` | none: it sends |

Each tool also gives a `content` text block, for an agent that calls it. The page reads only
`structuredContent`. A server can have other tools of its own (`send_message`,
`ask_question`, `mark_read`); the contract does not name them.

A server can take more input of its own, when each is optional. The email server's
`list_conversations` takes `folder` (see [Mail](#mail-a-conversation-is-a-thread)). A server
that already has a tool named `read_messages` with other input (Slack, WhatsApp) changes it
to take the contract's input, and keeps its own input as optional extras.

### list_conversations

Input, every field optional:

| Field | What |
|---|---|
| `cursor` | The `cursor` of the last answer, for the next page |
| `limit` | At most this many; 20 when left out, at most 100 |
| `unread` | `true`: only the conversations with unread messages |

`structuredContent` is `{ "conversations": [...], "cursor": "..." }`, the newest
`lastActivity` first. Each conversation:

| Field | Required | What |
|---|---|---|
| `source` | yes | The service: `email`, `slack`, `googlechat`, `whatsapp`, or the server's own word. The same word as a sender's `channel` |
| `id` | yes | The server's id for the conversation, which `read_messages` and `reply` take. Opaque to the daemon and the clients |
| `title` | yes | The channel's or space's name, the person's name, or the mail thread's subject |
| `kind` | yes | `channel` (many people read it), `direct` (a chat with one person or a small group) or `thread` (a mail thread) |
| `unread` | no | The service's own count of unread messages. Absent when the service does not say |
| `lastActivity` | no | The newest message's time, RFC 3339 |
| `link` | no | The conversation on the service's own site or app |

### read_messages

Input:

| Field | Required | What |
|---|---|---|
| `conversation` | yes | A conversation's `id` from `list_conversations` |
| `cursor` | no | The `cursor` of the last answer, for the older page |
| `thread` | no | A thread's id: only that thread's messages |
| `limit` | no | At most this many; 20 when left out, at most 100 |

`structuredContent` is
`{ "conversation": "...", "messages": [...], "cursor": "...", "untrusted": true }`, the
newest message first. Each message:

| Field | Required | What |
|---|---|---|
| `id` | yes | The server's id for the message |
| `conversation` | yes | Its conversation's `id` |
| `sender` | yes | Who sent it: a `ChannelSender` (#1762), below |
| `time` | yes | When it was sent, RFC 3339 |
| `text` | yes | Its text, as plain text. Outside content, below |
| `thread` | no | The id of the message that starts its thread. Absent when it is in no thread |
| `link` | no | The message on the service's own site or app |

`read_messages` reads only. It never marks a message as read (see
[Unread state](#unread-state-the-services-own)).

### reply (a later story)

Input: `conversation` (required), `thread` (the thread to answer in; absent: the conversation
itself) and `text` (required). Its `structuredContent` is the sent message, a
`MessagingMessage`. The page's Reply control is a later story of #4337, and waits for Alex's
approval (#3474).

## Paging

A cursor is a string that only its server reads: a Slack cursor, an IMAP UID, an offset. The
daemon and the clients never look into it. An answer with no `cursor` is the last page. A
cursor that the server cannot read any more (too old, its store moved on) is a tool error
that says so, and the caller starts again with no cursor.

## How the daemon reads it

Each machine's daemon has two methods for the Messages page (#4343,
`Go/internal/agentsd/messages.go`):

- **`messages/conversations`** calls `list_conversations` on every connector in the Messaging
  slot that follows the contract, in the folders' and the person's `mcp.json`. It merges the
  answers by `lastActivity`, newest first, one page at a time, with a cursor for each
  connector, as the forge lists merge forges. The daemon leaves out a connector that does
  not follow the contract and says nothing. It also leaves out a connector that fails or does
  not answer in 15 seconds, and gives that connector's error in `errors`. The other
  connectors' conversations still come.
- **`messages/read`** calls `read_messages` on the connector that lists the conversation,
  named by its `server` and `folder`.

The clients merge the machines' answers, one copy per conversation. The control plane only
relays them and never stores message text (`docs/explanation/direction.md`).

## Who sent it: the sender

`sender` is the same `ChannelSender` that a message event carries for a channel link (#1762,
[Channels](channels.md)):

| Field | Required | What |
|---|---|---|
| `channel` | yes | The service, the same word as the conversation's `source` |
| `identity` | yes | The sender on the service: Slack's `team/user`, the email address, the WhatsApp number, Google Chat's `users/…` |
| `name` | no | The name the service gives |
| `email` | no | The email address the service gives |
| `dkim` | no | Email only: the aligned DKIM result that the server read |

**Verified** is not a field. A chat service (Slack, Google Chat, WhatsApp) signs its users in,
so its `identity` is the service's word. An email `From` can be faked, so an email sender is
verified only when `dkim.result` is `pass`. A client can show an email sender that is not
verified as such. Whom an identity is linked to is the control plane's (`links/check`), not
the server's.

## Outside content

Every `text` is outside content: anyone who can write in the channel or send mail wrote it,
and its words can try to steer an agent.

- **In `structuredContent`,** `text` is the message's own text, and `untrusted` is always
  `true`. A client draws `text` as plain text, never as Markdown or HTML, and never opens a
  link in it by itself.
- **In `content`,** for an agent, the server writes a line that says the text is outside
  content, then the text in `<untrusted-content source="<source>">` and
  `</untrusted-content>`, as the email and WhatsApp servers do now
  (`Go/internal/emailmcp/body.go`). A tag of the same name inside the text is changed, so
  the text cannot close the mark.

## Decisions

The epic's open questions, settled for version 1.

### Mail: a conversation is a thread

Decided: a mail conversation is a **thread**, made from `References` and `In-Reply-To` (and
the subject when a reply, `Re: …`, has neither), `kind: thread`, because that is what a person reads
as one conversation, and a folder holds thousands of unrelated mails. The folder is a
filter: the email server's `list_conversations` takes an optional `folder` (`INBOX` when left
out) and lists the threads that have mail in it, by its newest mail there. `read_messages`
gives the thread's mail in that folder and in the Sent folder, so the person's own answers
are in it (#4340). Alex can overrule.

### Unread state: the service's own

Decided: `unread` is the **service's own** state (IMAP `\Seen`, Slack's unread count, Google
Chat's read state), and Agents keeps no read mark of its own, because the person's other
apps then agree with the page, and Agents stores nothing (no message text on the control
plane, `docs/explanation/direction.md`). Reading on the page marks nothing. A later Mark
read control calls the server's own `mark_read`, as the email server has now. A service that
gives no unread state leaves `unread` out. Alex can overrule.

### History that a service does not give

Decided: a server reads history from its service where the service allows it. Where it does
not (WhatsApp's Cloud API; Google Chat without `chat.app.messages.readonly`), the server keeps
a **bounded store** of the messages that it received, as the WhatsApp server does (#4341: the
newest 2,000 for 30 days, both ways, in `~/.agents/whatsapp/`), and pages that, because the bounded-data rule says every store has a limit. A
server says nothing about where its history ends: the last page has no `cursor`. Alex can
overrule.

## See also

- [Connector levels](../explanation/connector-levels.md)
- [Channels](channels.md)
- [Integrations](integrations.md)
