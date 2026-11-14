---
diataxis: how-to
devices: [mac]
description: Make a Slack app for Agent Loops, add the Slack connector with its two tokens, and let a workflow start an agent from a Slack message or a question's answer.
---

# Reach agents from Slack

The `slack` connector lets agents talk in a Slack workspace, and lets a Slack message start
work. It is `slack-mcp`, a small server that Agent Loops makes (#1351). It speaks as the bot of a
Slack app that you make, and it uses Socket Mode, so Slack needs no public address.

- **The event** `message.received`: a message came into a channel the bot is in, or to the
  bot directly. Replies in threads come too; the bot's own messages and other bots' do not.
  Filters: `channel`, `user`, `thread` (the ts of a thread's first message) and `mentions`
  (`true`: only messages that mention the bot, and direct messages). Its data is the channel,
  the user, the message's ts and its thread's, and whether it mentions the bot. It never
  holds the text.
- **The event** `question.answered`: someone pressed an option on a question that
  `ask_question` posted. Filters: `question` and `channel`. Its data is the question's id,
  who answered, and the option (its words and its place, from 0). Only the first answer
  counts. The question then says who answered, and its buttons go.
- **The tools:** `list_conversations` and `list_channels` (where the bot is),
  `read_messages` (a conversation's messages, or a thread's, newest first, a page at a time
  by its `cursor`), `send_message` and `ask_question` (options as buttons). `read_messages` gives the text
  marked as outside content: an agent reads it as data, never as instructions. The server
  refuses to send `@channel`, `@here` or `@everyone`. It cannot edit or delete a message.
  `list_conversations` and `read_messages` follow the
  [messaging contract](../reference/messaging-contract.md), so the Messages page can read
  Slack. Slack gives a bot no unread counts, so a conversation has no `unread`.

A message acts as a person only when that person has linked their Slack user (see
[Channels](../reference/channels.md)). The identity is the workspace and the user, as
`T0123/U0456`. The server gives Slack's name and email for the user, so the first message
asks the person whose sign-in email is that email.

## Before you start

- A Slack workspace where you can make and install an app.
- Agent Loops on the Mac carries `slack-mcp`, and every Linux host installs it beside agentsd.

## Make the Slack app

1. Open <https://api.slack.com/apps>, choose **Create New App ▸ From a manifest**, and
   choose your workspace.
2. Paste this manifest, and change the name if you want:

   ```yaml
   display_information:
     name: Agents
   features:
     bot_user:
       display_name: Agents
       always_online: true
   oauth_config:
     scopes:
       bot:
         - app_mentions:read
         - channels:history
         - channels:read
         - chat:write
         - groups:history
         - groups:read
         - im:history
         - im:read
         - mpim:history
         - mpim:read
         - users:read
         - users:read.email
   settings:
     event_subscriptions:
       bot_events:
         - app_mention
         - message.channels
         - message.groups
         - message.im
         - message.mpim
     interactivity:
       is_enabled: true
     socket_mode_enabled: true
   ```

3. Choose **Install to Workspace**, and allow it. Copy the **Bot User OAuth Token**
   (`xoxb-…`) from **OAuth & Permissions**.
4. In **Basic Information ▸ App-Level Tokens**, choose **Generate Token and Scopes**, add
   the scope `connections:write`, and copy the token (`xapp-…`).
5. In Slack, invite the bot to each channel it must hear: `/invite @Agents`.

## Add the connector

1. Add **Slack** from the **Agent Loops** marketplace in the catalogue (**Settings ▸ Agent
   Configuration ▸ Connectors ▸ Add Connector…**, or **Change… ▸ Slack…** in the connectors
   set-up's **Messaging** slot).
2. It asks for `SLACK_BOT_TOKEN`, the `xoxb-` token, and `SLACK_APP_TOKEN`, the `xapp-`
   token. Their values are sealed in `~/.agents-secrets/sealed.json`.
3. Choose **Add**. The entry it writes runs `slack-mcp` hosted, one copy on the host:

   ```json
   { "mcpServers": { "slack": { "command": "slack-mcp", "hosted": true,
     "env": { "SLACK_BOT_TOKEN": "${SLACK_BOT_TOKEN}", "SLACK_APP_TOKEN": "${SLACK_APP_TOKEN}" } } } }
   ```

## Start work from Slack

- A workflow on `message.received` with `mentions: true` starts an agent when someone
  mentions the bot. The agent reads the message with `read_messages` (`conversation` and
  `thread`: the event's `channel`, and its `threadTs` or else its `ts`), and answers in the
  thread with `send_message`. See
  [Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md).
- An agent that needs a choice from someone asks with `ask_question`, and waits for
  `question.answered` with the `question` id it got.

## Limits

- Slack sends each event once, to one open connection, and only while one is open. Run one
  `slack-mcp` for each Slack app: a second copy gets a share of the events. A message that
  comes while no copy runs is lost.
- The server keeps the last 1,000 events in memory. A poll after more than that says
  `truncated`.
