---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Answer an agent's permission request or question from the Mac, the iPhone or iPad, or a notification.
---

# Answer a question or a permission request

An agent stops and waits for you in three ways: it asks permission to do something, it
asks a question with answers to pick from, or it ends its turn with a question in words.
Whichever it is, the agent and its folder say **Needs you** until you answer.

## Before you start

- To answer away from the Mac, the iPhone or iPad app paired with it. See the
  [tutorials](../tutorials/index.md).

## Steps

1. Find the agent that is waiting. Any of these takes you to it:
   - On the Mac, a folder with a dot beside it in the list; on its page, the agent under
     **Needs you**.
   - On iPhone or iPad, the same, in the folder list and on the folder's page.
   - A notification. It names the agent, the folder and what is wanted; click or tap it
     to open the conversation with the question in front of you. You get one
     notification, on the device you used last: the Mac if you are at it, otherwise the
     iPhone or iPad you touched most recently. None comes if you are already reading
     that conversation.
2. Answer the card in the conversation. It is at the end of the conversation, after the
   agent's work and any prompt waiting to be sent, just above the prompt. It scrolls with
   the conversation. When you have scrolled up, **↓** above the prompt takes you back to the
   end, and to the card.
   When the agent asks about several things at once — several file edits, for example —
   each question stays as its own card, in the order asked, until you answer it.
   Answering one leaves the others.
   - **Permission.** The card names what the agent wants to do, such as the command it
     wants to run or the file it wants to change. The buttons are the agent's own
     choices, usually **Yes**, **Yes, and don't ask again…** (the rest of the button
     names what it will stop asking about, such as *for swift test \* commands*) and
     **No**. On iPhone and iPad the card also shows
     the full command or change, and says, for example, **Yes — telling your Mac** while
     the answer goes through.
   - **A question with choices.** Click or tap the answer. **No thanks** declines to
     answer; the agent carries on without one.
   - **Several questions at once.** They come one to a page. Choosing an answer moves to
     the next page. Use **Next** to skip a question you want to leave, the back arrow to
     go back, and **Submit** on the last page. The Mac shows where you are as **2/3**;
     iPhone and iPad as **Question 2 of 3**. If **Submit** does not go, the line beside
     it names the question that still needs an answer (marked **needed**).
   - **A secret.** An agent that needs an API key or a token asks for it by name, such as
     `OPENAI_API_KEY`, with a lock beside it, why it needs it and, when it knows, a link to
     where you get it. Paste it into the masked field and choose **Save securely**. It is
     saved to your secrets on the machine that runs the agent (`~/.agents-secrets/secrets.env`),
     and the agent gets its name, never the value; the chat shows only that it was saved.
     **No thanks** tells the agent you did not give it. A notification of it has no **Reply**:
     open the conversation to answer it.
   - **A link to open.** Some agents ask you to do something in the browser, such as
     sign in. Click **Open**, do it, then click **Done**, or **Gave up** if you could not.
3. For a question in words (the agent's turn has ended and its summary says **Waiting on
   your answer**), type your answer in the prompt and send it, as you would any prompt.

   Grok always asks this way: its own question cards have no way to reach the app, so
   Grok's questions arrive as a turn that ends waiting on your answer.

Answer from wherever is closest. Answering on one device clears the card and the
notification everywhere else.

Once you answer a card with questions, the conversation keeps what you said, in a bubble
of yours: each question, and under it your answer in the card's own words, such as the
choice you picked, several choices joined with commas, or what you typed in the box beside
a choice. A question you left empty is left out. A card you declined or closed says **You
declined the agent's form** or **The form was closed**.

Cursor's questions come as the same card, one question to a page; any of them can be left
empty. A question with choices shows those choices, and a question without choices has a
text box.

When Cursor, Grok or OpenCode is set to **Always-approve** under its prompt, every
permission request from that runtime is answered for you: no card, no **Needs you**, and
no notification. The value applies to every agent on that runtime, including workflow
agents and agents in server folders. Questions that are not permission to act still wait
as above, including Grok's questions in words. Claude, Codex, Antigravity and
Copilot keep asking the way they always have.

### When a runtime's sandbox could not start

Some runtimes run commands in a sandbox of their own, and on some computers or servers
that sandbox cannot be set up. When that happens the agent stops, says **Its sandbox could
not start**, and puts a card in the conversation, such as **Claude's sandbox could not
start**, with **Show error details** for the runtime's own words.

- **Continue without sandbox** turns that runtime's sandbox off for this agent only, and
  carries on: your prompt is sent again, or, if some commands already ran, the agent is
  asked to carry on rather than start over. The card says which before you choose. For
  Codex it means **Full access**, so its approval prompts are off too. The app's own
  folder and tool rules still apply.
- **Keep stopped** leaves the agent stopped. Nothing is ever retried without the sandbox
  until you choose it.

Where the app cannot turn a runtime's sandbox off, the card says so and has no **Continue**.
The same card, and the same choice, are on iPhone and iPad. A command refused *inside* a
working sandbox, such as a write outside the folder, is an ordinary failed command and
brings no card.

## If it doesn't work

- **The card is gone but the agent is not working.** It stopped, or the app restarted,
  before you answered. The conversation says **Nobody answered this question before the
  agent ended.** Send a prompt telling it to carry on.
- **No notification on the iPhone or iPad.** Check that notifications are allowed for the
  app on the device. On the Mac, **Settings ▸ Control plane ▸ Clients** lists each
  paired device.
