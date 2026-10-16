---
diataxis: how-to
devices: [mac, iphone, ipad, browser]
description: Get an agent's waiting question in Slack, and answer it with a button or a reply in its thread.
---

# Answer questions from Slack

When an agent asks you a question and you are away from your Mac, the question can go to
your Slack direct messages. Its options are buttons. Press one, or reply in the message's
thread, and the agent has its answer.

This is a first version (#1009). It does only that: questions that agents ask with a form,
such as `ask_form`. It does not start agents, say when an agent is done, or answer tool
approvals.

## How it works

- **The control plane connects out to Slack** with Socket Mode. You need no public address
  and no relay.
- **Only you.** Questions go to the one Slack member you name, and only that member's
  buttons and replies answer them.
- **Only when you are away.** A question goes to Slack when it would go to your phone: you
  are not at your Mac and not looking at that conversation. When you answer it in Agents,
  or come back to the Mac, its Slack message says so and loses its buttons.
- **One Slack app for each control plane.** Slack shares its events among all the
  connections made with one app token, so do not give the same tokens to two control
  planes.

## 1. Make a Slack app

You need a Slack workspace where you can add apps.

1. Open <https://api.slack.com/apps> and choose **Create New App ▸ From a manifest**.
2. Pick your workspace.
3. Choose **YAML**, then paste this, in place of what is there:

    ```yaml
    display_information:
      name: Agents
      description: Your agents' questions, answered from Slack
    features:
      bot_user:
        display_name: Agents
        always_online: false
      app_home:
        home_tab_enabled: false
        messages_tab_enabled: true
        messages_tab_read_only_enabled: false
    oauth_config:
      scopes:
        bot:
          - chat:write
          - im:write
          - im:history
    settings:
      event_subscriptions:
        bot_events:
          - message.im
      interactivity:
        is_enabled: true
      org_deploy_enabled: false
      socket_mode_enabled: true
      token_rotation_enabled: false
    ```

4. Choose **Next**, then **Create**.

The scopes are what the app needs and no more:

| Scope | Why |
|---|---|
| `chat:write` | Send a question, and change it once it is answered. |
| `im:write` | Open your direct messages with the app. |
| `im:history` | Read your replies in a question's thread. |

## 2. Get the two tokens

1. **App token.** On the app's **Basic Information** page, under **App-Level Tokens**,
   choose **Generate Token and Scopes**. Name it `socket`, add the scope
   `connections:write`, and choose **Generate**. Copy the token. It starts with `xapp-`.
2. **Bot token.** Open **Install App** and choose **Install to Workspace**, then **Allow**.
   Copy the **Bot User OAuth Token**. It starts with `xoxb-`.

Treat both as passwords. Do not paste them in a chat, an issue or a commit.

## 3. Find your member ID

In Slack, open your profile, choose **⋯**, then **Copy member ID**. It starts with `U`.

## 4. Turn it on

Open **Settings ▸ Channels ▸ Slack**, on your Mac, iPhone, iPad or in a browser:

1. Paste the app token and the bot token. They are written to the control plane's secrets,
   and are never shown again: the section says only **Set** or **Not set**.
2. Enter your member ID.
3. Turn on **Send questions to Slack**, then choose **Save**.

The section says **Connected** when the control plane has reached Slack. If it says **Not
connected**, the words after it say what to fix: a token Slack refused, or a scope missing.

### Or put the tokens in the file yourself

The tokens are kept in `~/.agents-secrets/channels.env` on the computer that runs the control
plane: your Mac, or a server's home folder. To write that file by hand:

```sh
mkdir -p -m 700 ~/.agents-secrets
touch ~/.agents-secrets/channels.env
chmod 600 ~/.agents-secrets/channels.env
open -e ~/.agents-secrets/channels.env
```

Put these two lines in it, with your own tokens, and save:

```sh
SLACK_APP_TOKEN=xapp-…
SLACK_BOT_TOKEN=xoxb-…
```

Then set your member ID and the switch in Settings ▸ Channels ▸ Slack.

## Answer a question

A question arrives as a direct message from **Agents**: the project and the conversation,
then the question.

- **A button** answers it with that option.
- **A reply in the thread** answers a question that wants words. For a question with
  options, a reply that names an option picks it. Where the question takes a note beside its
  options, your words are kept, and go with the button you press next.
- A form with more than one question says **Answer this one in Agents**.

When it is answered, the message says **Answered:** and what you chose.

## Turn it off

Turn off **Send questions to Slack** in Settings ▸ Channels ▸ Slack and choose **Save**. To take the tokens
away too, delete `~/.agents-secrets/channels.env`, and remove the app at
<https://api.slack.com/apps>.
