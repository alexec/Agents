---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Set up a Google Chat app for Agent Loops, so that a person can start an agent from Google Chat, see what needs them there, and answer an agent's question with a button.
---

# Use Google Chat

The `googlechat` connector brings a Google Chat app to your agents (#1016). It is
`googlechat-mcp`, a small server that Agent Loops ships. Agent Loops on the Mac carries it, and every Linux
host installs it beside agentsd.

- **The events:** `message.received`, a person wrote to the app (a direct message, or a message
  that @mentions it in a space), with the text; and `question.answered`, a person pressed an
  option on a question the app asked. A workflow or a wait can use them. See
  [Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md).
- **The tools:** `list_spaces`, the spaces the app is in; `send_message`, a message as the
  app, in a thread when given; and `ask_question`, a question with a button for each option.
  The first press comes back as `question.answered`, and the card then says who answered and what.
- **The messaging tools:** `list_conversations` and `read_messages`, as the
  [messaging contract](../reference/messaging-contract.md) says them (#4342), so the Messages
  page can read Google Chat. See [What `read_messages` gives](#what-read_messages-gives).

The server pulls the app's events from a Pub/Sub subscription. It connects out to Google, so
the machine needs no public address. The app can post only in a space where a person added
it.

## What `read_messages` gives

`list_conversations` gives the spaces, group chats and direct messages that the app is in,
the newest activity first. Google Chat gives an app no read state, so a conversation has no
unread count. What `read_messages` gives depends on one approval:

- **With `chat.app.messages.readonly`:** a space's whole history, and a thread's, from the
  Chat API, a page at a time. An app reads a space as itself only when a Workspace admin
  approved this scope for it once. See
  [Let the app read a space's history](#let-the-app-read-a-spaces-history).
- **Without it:** only what the server kept: the messages sent to the app (a direct message,
  or an @mention in a space) and what the app posted, for a day, the newest 1,000. The server
  keeps them from the time that it starts to read or to poll, and forgets them when it stops.
  The last page has no cursor, also where older messages are in Google Chat.

When Google refuses the scope, the server asks again after 10 minutes, so an approval works
without a restart.

### Let the app read a space's history

A Workspace admin approves `https://www.googleapis.com/auth/chat.app.messages.readonly` for
the Chat app, once. Google's
[Authenticate as a Chat app with administrator approval](https://developers.google.com/workspace/chat/authenticate-authorize-chat-app#admin-approval)
says how. The server needs no change: it uses the same service account key.

## A message acts only as a linked person

Each event names who sent it: their Google Chat user, name and email address. The machine
raises the event only when that person linked their Google Chat user to themselves. The first
message from a user who is not linked starts nothing, and asks the person whose sign-in email
is the user's email to approve the link. See [Channels](../reference/channels.md).

## Before you start

- A Google Workspace account. Google Chat apps are for Workspace, not for personal Google
  accounts.
- A Google Cloud project for the app, which you can make at no cost.

## Set up the Chat app

1. In the Google Cloud console, open your project and turn on the **Google Chat API** and
   the **Cloud Pub/Sub API**.
2. **Pub/Sub ▸ Topics ▸ Create topic**, such as `agents-chat`, with a default subscription
   named `agents-chat` (the name the server pulls when you set no other). Pull, not push.
3. On the topic, **Add principal** `chat-api-push@system.gserviceaccount.com` with the role
   **Pub/Sub Publisher**. Google Chat publishes the app's events as this account.
4. **IAM ▸ Service accounts ▸ Create service account**, such as `agents-chat`. On the
   subscription, give it the role **Pub/Sub Subscriber**. Then **Keys ▸ Add key ▸ JSON**,
   and keep the file.
5. **Google Chat API ▸ Configuration:** give the app a name and an avatar, turn on
   **Receive 1:1 messages** and **Join spaces and group conversations**, choose
   **Connection settings ▸ Cloud Pub/Sub**, and give the topic's name
   (`projects/<project>/topics/agents-chat`). Under **Visibility**, choose who can find it.

## Add the connector

1. Put the key in your secrets, in **Settings ▸ Secrets**, as `GOOGLE_CHAT_CREDENTIALS`: the
   key file's JSON, or its path on the machine. When the subscription is not
   `agents-chat` in the key's project, also set `GOOGLE_CHAT_SUBSCRIPTION`, as
   `projects/<project>/subscriptions/<name>` or a name in the key's project.
2. Add **Google Chat** from the **Agent Loops** marketplace in the catalogue, or by hand in the
   folder's `.agents/mcp.json`:

   ```json
   { "mcpServers": { "googlechat": { "command": "googlechat-mcp", "hosted": true,
       "env": { "GOOGLE_CHAT_CREDENTIALS": "${GOOGLE_CHAT_CREDENTIALS}" } } } }
   ```

3. In **Project Settings ▸ Agent Configuration ▸ Connectors**, choose **Approve** on
   `googlechat`. See [Add a connector by hand](add-a-connector-by-hand.md).
4. In Google Chat, find the app by its name and send it a message, or add it to a space.

## Start an agent from Google Chat

A workflow on `message.received` starts an agent on each message. Save this as
`.agents/workflows/start-from-google-chat.md`:

```markdown
---
name: Start from Google Chat
on:
  - message.received:
      server: googlechat
      direct: "true"
agent: new
labels: [googlechat]
when-done: archive
---

A person asked for this in Google Chat. Do what the message's text asks, as you would for
that person in the app. When you are done, call send_message with the event's space and
thread, and say in one or two lines what you did.
```

`direct: "true"` listens only to direct messages. Leave it out to hear @mentions in spaces
too, or give `space` to hear one space only, or `text` (such as `start *`) to hear only some
messages.

## See what needs you, and answer from Google Chat

Two workflows bring an agent's question to a space and its answer back. The first runs when
an agent asks a question, and posts it with `ask_question`. Give it the id of the session, so
the answer can find its way back. The second runs on `question.answered`.

```markdown
---
name: Ask in Google Chat
on:
  - agent.asked_form
agent: new
when-done: archive
---

Another session asked a question. Read it with read_session. Then call ask_question in
spaces/AAAA (your direct message space with the app: list_spaces names it), with the
session's title as title, its question, an option for each of its options, and the
session's id as id.
```

```markdown
---
name: Answer from Google Chat
on:
  - question.answered:
      server: googlechat
agent: new
when-done: archive
---

A person answered a question in Google Chat. The event's question is the session's id.
Send that session the answer's label with message_session, as the person's answer.
```

## When it does not work

- **Not connected:** `GOOGLE_CHAT_CREDENTIALS` is not set on the machine that runs the
  server, or it is not a service account key.
- **Refused:** the service account needs **Pub/Sub Subscriber** on the subscription; the
  Chat API turned on; the app in the space it posts to.
- **No events:** the topic needs `chat-api-push@system.gserviceaccount.com` as a publisher,
  and the Chat app's connection must be Cloud Pub/Sub with that topic. The sender must also
  have linked their Google Chat user (see above).
- **`read_messages` gives only recent messages:** the app has no `chat.app.messages.readonly`
  (see [What `read_messages` gives](#what-read_messages-gives)).
- The server acknowledges each event when it reads it, and keeps the newest 1,000 for a day.
  An event that comes while the machine is asleep waits in the subscription, for up to seven
  days by Pub/Sub's default.
