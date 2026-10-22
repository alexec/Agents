---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Send a prompt while an agent is still working, put it into the running turn with Send now, change it while it waits, bring back an earlier prompt, and quote a reply.
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

## Bring back a prompt you sent before

Use Up Arrow and Down Arrow in an empty prompt to send a prompt again, or to change it a
little first, without typing it all again. It works as the history does in a terminal.

1. Click in the prompt. Make sure it is empty.
2. Press Up Arrow. The last prompt you sent in this session comes back.
3. Press Up Arrow again to go further back. Press Down Arrow to come forward again. Past the
   newest one, the prompt is empty again.
4. Press Return to send it, or change it first.

Only your own prompts come back: not a message from another agent, and not a question the
app asked. A prompt you sent twice in a row comes back once.

When you change a prompt that came back, it is yours: the arrow keys move the caret again,
as in any text. While a list of commands (`/`) or files (`@`) shows, the arrow keys move
through the list instead.

On the Mac and on the web page this works in every prompt. On iPhone and iPad it needs a
keyboard connected to the device.

## Change a waiting prompt

You can change the words of a prompt while it waits its turn. It keeps its place in the
queue, so you do not have to take it back and send it again behind the others.

1. On the waiting bubble, click or tap the pencil (**Edit queued prompt**). On the web page
   it is **Edit**.

   The words open in an editor in the bubble's place.
2. Change the words.
3. Click **Save**, or press Command-Return. To keep the words as they were, click
   **Cancel**, or press Escape.

You can change only your own prompts. A prompt that another agent sent has no Edit.

If the prompt went to the agent before you saved, your change cannot go with it. The app
says **That prompt was sent before your change. Your words are in the prompt bar.** Send
them from there as a new prompt.

## Quote a reply in your prompt

Quote part of a reply when you want to say which words you mean, for example "this step
fails". The quote goes at the end of what you have typed, as a Markdown quote (each line
starts with `>`), with an empty line after it for your own words.

**On the Mac**

1. Select the words in the agent's reply.
2. Choose **Session ▸ Quote in Prompt**, or press Shift-Command-' (apostrophe).

If no words are selected, the Mac beeps and quotes nothing. Where the reply's own
right-click menu shows **Quote in Prompt**, it quotes the selected words, or the whole
reply when none are selected.

**On iPhone and iPad**

Touch and hold the reply, then tap **Quote in Prompt**. It quotes the whole reply, because
the device does not tell the app which words are selected. Delete the lines you do not need.

**On the web page**

Select words in the reply, if you want only part of it. Then point at the reply and click
**Quote**, beside **Copy**. It quotes the selected words, or the whole reply when none are
selected.

## If it doesn't work

- **There is no Send now.** The agent's runtime cannot take words mid-turn, or the agent
  is still starting. The prompt goes when the turn ends; or stop the agent (Command-.)
  and send it then.
- **Could not send that now. It is still waiting.** The runtime turned it down. It stays
  at the front of the queue and goes when the turn ends.
- **Your Mac is not answering, so that could not be sent.** On iPhone or iPad: the Mac is
  out of reach. Try again when it answers.
