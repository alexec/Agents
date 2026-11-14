---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Set up a WhatsApp Business number for Agent Loops, so that a person can start an agent from WhatsApp, see what needs them there, and answer an agent's question with a button.
---

# Use WhatsApp

The `whatsapp` connector brings a WhatsApp Business number to your agents (#1352). It is
`whatsapp-mcp`, a small server that Agent Loops ships. Agent Loops on the Mac carries it, and every Linux
host installs it beside agentsd.

- **The events:** `message.received`, a person wrote to the number, with the text; and
  `question.answered`, a person pressed an option on a question the number asked. A workflow
  or a wait can use them. See
  [Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md).
- **The tools:** `send_message`, a text as the number; `ask_question`, a question with a
  button for each option (a list for more than three); `send_template`, a template that
  WhatsApp approved; and `list_conversations` and `read_messages`, the people the number
  wrote with and their messages, both ways, newest first (the
  [messaging contract](../reference/messaging-contract.md)).

WhatsApp gives no history, so the server keeps its own: each message the webhook gets and
each message the number sends, the newest 2,000 for 30 days (4 MB of text at most), in
`~/.agents/whatsapp/<phone number id>.json` (`WHATSAPP_STORE_DIR` puts it somewhere else).
A message from before the server ran, or older than that, is not there.

## The 24-hour window

WhatsApp takes a free message (`send_message`, `ask_question`) only within 24 hours of the
person's last message to the number. After that, the number can send only a template that
WhatsApp approved, with `send_template`. So an agent that writes first sends a template, such
as "An agent needs you", and asks its question when the person answers. When WhatsApp refuses
a message for the window, the tool says to use `send_template`.

## The webhook needs a public address

WhatsApp sends what people write to a webhook: an HTTPS address that Meta can reach. The
server serves the webhook itself, on `127.0.0.1:8797`, and takes a call only when the Meta
app's secret signed it. You put a public HTTPS address in front of it:

- **A tunnel,** such as `cloudflared tunnel --url http://127.0.0.1:8797`, which gives an
  address such as `https://name.trycloudflare.com`. A quick tunnel's address changes when
  it starts again; a named tunnel keeps it.
- **The machine's reverse proxy,** on a server that has a public address and a certificate.
  Set `WHATSAPP_WEBHOOK_ADDR` to where the proxy sends the calls.

The server listens on the machine that runs it, so run it on one machine only: a second
server cannot listen on the same address, and says so.

## A message acts only as a linked person

Each event names who sent it: their number and the name on their WhatsApp profile. The
machine raises the event only when that person linked their number to themselves. WhatsApp
gives no email address, so the first message from a number that is not linked asks the
admins, who send the request on to the person. See [Channels](../reference/channels.md).

## Before you start

- A Meta developer account, at developers.facebook.com.
- A Meta business portfolio. The app makes one for you when you add WhatsApp.

## Set up the WhatsApp app

1. In **My Apps ▸ Create app**, choose **Business**, then add the **WhatsApp** product.
   Meta gives the app a test number.
2. On **WhatsApp ▸ API Setup**, copy the **Phone number ID**. A test number sends only to the
   numbers in its list: add your own number there. To use your own business number, add it
   on the same page.
3. In **Business settings ▸ Users ▸ System users**, add a system user, give it the app, and
   **Generate new token** with `whatsapp_business_messaging` and
   `whatsapp_business_management`, with no expiry.
4. On **App settings ▸ Basic**, show and copy the **App secret**.
5. Choose a verify token: any word of your own, such as a long random one.

## Add the connector

1. Put the values in your secrets, in **Settings ▸ Secrets**: `WHATSAPP_TOKEN` (the system
   user's token), `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_APP_SECRET` and
   `WHATSAPP_VERIFY_TOKEN`. When the webhook is not to listen on `127.0.0.1:8797`, also set
   `WHATSAPP_WEBHOOK_ADDR`.
2. Add **WhatsApp** from the **Agent Loops** marketplace in the catalogue, or by hand in the
   folder's `.agents/mcp.json`:

   ```json
   { "mcpServers": { "whatsapp": { "command": "whatsapp-mcp", "hosted": true,
       "env": { "WHATSAPP_TOKEN": "${WHATSAPP_TOKEN}",
                "WHATSAPP_PHONE_NUMBER_ID": "${WHATSAPP_PHONE_NUMBER_ID}",
                "WHATSAPP_APP_SECRET": "${WHATSAPP_APP_SECRET}",
                "WHATSAPP_VERIFY_TOKEN": "${WHATSAPP_VERIFY_TOKEN}" } } } }
   ```

3. In **Project Settings ▸ Agent Configuration ▸ Connectors**, choose **Approve** on
   `whatsapp`. See [Add a connector by hand](add-a-connector-by-hand.md).
4. Start the tunnel, or set up the reverse proxy.
5. On **WhatsApp ▸ Configuration ▸ Webhook**, choose **Edit**. Give the public address
   followed by `/webhook` as the **Callback URL**, and your verify token. Choose **Verify and
   save**: Meta calls the server, which answers with the verify token. Then, under **Webhook
   fields**, subscribe to `messages`.
6. Send the number a message from your phone.

## Start an agent from WhatsApp

A workflow on `message.received` starts an agent on each message. Save this as
`.agents/workflows/start-from-whatsapp.md`:

```markdown
---
name: Start from WhatsApp
on:
  - message.received:
      server: whatsapp
      text: "start *"
agent: new
labels: [whatsapp]
when-done: archive
---

A person asked for this in WhatsApp. Do what the message's text asks, as you would for that
person in the app. When you are done, call send_message to the event's space, with the
event's message as reply_to, and say in one or two lines what you did.
```

`text: "start *"` hears only messages that start with "start". Leave it out to hear every
message, or give `space` (a number) to hear one person only.

## See what needs you, and answer from WhatsApp

Two workflows bring an agent's question to your phone and its answer back. The first runs
when an agent asks a question, and sends it with `ask_question`. Give it the id of the
session, so the answer can find its way back. The second runs on `question.answered`.

First make a template for when the 24-hour window is closed: in **WhatsApp Manager ▸
Message templates ▸ Create template**, a **Utility** template such as `agent_needs_you`,
with the body `{{1}} needs you. Reply to see the question.` WhatsApp approves it, usually in
minutes.

```markdown
---
name: Ask in WhatsApp
on:
  - agent.asked_form
agent: new
when-done: archive
---

Another session asked a question. Read it with read_session. Then call ask_question to
15551234567 (your number), with the session's title as title, its question, an option for
each of its options, and the session's id as id. If WhatsApp says the 24-hour window is
closed, call send_template with agent_needs_you and the session's title as its parameter
instead, and stop.
```

```markdown
---
name: Answer from WhatsApp
on:
  - question.answered:
      server: whatsapp
agent: new
when-done: archive
---

A person answered a question in WhatsApp. The event's question is the session's id. Send
that session the answer's label with message_session, as the person's answer.
```

## When it does not work

- **Not connected:** one of the four values is not set on the machine that runs the server.
  The error names the ones that are missing.
- **Meta cannot verify the webhook:** the tunnel or the proxy must reach the server's
  address, and the verify token must be `WHATSAPP_VERIFY_TOKEN`.
- **No events:** subscribe the webhook to the `messages` field; check that
  `WHATSAPP_APP_SECRET` is the app's secret (the server refuses a call with another
  signature, and logs it); the sender must have linked their number (see above).
- **Refused, the token:** make the system user's token again.
- **Refused, a test number:** add the person's number to the test number's list on
  **WhatsApp ▸ API Setup**.
- The server keeps the newest 1,000 messages for a day, in memory. A message that comes while
  the server is not running is not kept: Meta tries the webhook again for a while, then
  gives up.
