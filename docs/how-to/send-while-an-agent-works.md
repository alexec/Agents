---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Send a prompt while an agent is still working, and put it into the running turn with Send now.
---

# Send a prompt while an agent is working

You do not have to wait for an agent to finish before you say the next thing. A prompt
you send while it is working waits its turn and goes when the turn ends. On runtimes that
can take words mid-turn, **Send now** puts it into the turn that is running instead, so
you can steer the agent without stopping it.

## Before you start

- An agent that is working. See the [tutorials](../tutorials/index.md).
- For **Send now**, a runtime that can take words in the middle of a turn: today Claude
  and Codex. The app goes by what the runtime says about itself when it starts, not by
  its name. On other runtimes the prompt still waits its turn.

## Steps

1. Type in the prompt and press Return, as you would at any time.

   Your prompt appears at the foot of the conversation, in a dashed bubble headed
   **Waiting its turn**. It goes by itself when the turn ends. Send several and they go
   one at a time, in order.
2. To put it in now, click or tap **Send now** on the waiting bubble.

   It is there while the agent is working or waiting on you, not while it is still
   starting. Your words appear in the conversation where they went in, and the agent
   takes them into account as it carries on.
3. To take a waiting prompt back, click **×** beside it (**Do not send this**).

If the agent is waiting on a permission card when you click **Send now**, the card stays
as it is. Answer it, and the agent reads your words after it. If the turn ended just as
you clicked, your prompt goes as the next prompt instead.

## If it doesn't work

- **There is no Send now.** The agent's runtime cannot take words mid-turn, or the agent
  is still starting. The prompt goes when the turn ends; or stop the agent (Command-.)
  and send it then.
- **Could not send that now. It is still waiting.** The runtime turned it down. It stays
  at the front of the queue and goes when the turn ends.
- **Your Mac is not answering, so that could not be sent.** On iPhone or iPad: the Mac is
  out of reach. Try again when it answers.
