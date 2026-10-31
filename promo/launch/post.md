<!-- Launch post for the public release (#1913). A draft for Alex to read and publish; agents
     never post it. Before publishing, fill in the two TODO links: the App Store page (#659)
     and one integration video (#1793). Every other link works today. -->

# Run your coding agents together, and answer them from your phone

I use coding agents every day. For most of this year I ran several of them at once, in
terminal tabs, and I spent a lot of my time finding out which one was stuck. One was waiting
on a question I had not seen. Two were fighting over the iOS simulator. A third had finished
an hour ago, and I had not noticed.

So I built an app for it. On your Mac and your phone it is called Agents, and in the App Store
it is **Loops: Agent Workflows**. Today it is open to everyone.

## What it does

Agents runs the coding agents you already have: Claude, Codex, Gemini, Antigravity, Grok,
Copilot, Cursor and OpenCode. Each one uses your own sign-in and your own plan. Agents brings
no model and no bill of its own, and you keep your editor.

What it adds is a place to run several of them at once:

- **A list sorted by who needs you.** Every agent is in one group: Needs you, Waiting,
  Working, Done or Paused. When an agent ends its turn, it says in one sentence how it went.
  I read the list and I know what to open next.
- **The work, beside the chat.** When an agent writes a plan or a review, the document opens
  beside the conversation and fills in as the agent writes. You can type on it while it
  grows. Code changes are coloured down to the word.
- **Agents that take turns.** Two agents never use the simulator at once. The second one
  takes a place in line, ends its turn and costs nothing until the simulator is free.
- **Agents that wait.** An agent can wait for another agent to finish, for a branch to move
  or for a pull request. Nothing polls. It wakes up when the thing happens.
- **Workflows.** A Markdown file in your repository starts an agent on a schedule or when
  something happens. It lives beside the code, and you review it like code.

Your agents run in a helper on your Mac, so they keep going when you close the window. On your
iPhone, your iPad or a browser you see the same list. You can answer a question from the
sofa, and when an agent needs you, the device you used last gets a notification.

The work stays on machines you own: your Mac, or a Linux server of your own. Every agent's
spending, on every runtime, adds up to one figure for the day.

TODO: the integration video (#1793), as a YouTube link.

## Who it is for

It is for developers who already use a coding agent and want to run more than one. If you
want one assistant beside the file you are editing, the agent in your editor is closer to
hand. If your computer should be off while the work happens, a cloud agent does that, and
Agents does not. Agents needs a Mac.

## What you need

- A Mac, with Agents Host. It is a free download, and the app shows you where to get it.
- An account with at least one of the coding agents above.
- If you want to follow along on the move, an iPhone or iPad.

## Get it

- The app: TODO the App Store link (#659).
- The site: [agentloops.dev](https://agentloops.dev/)
- The docs, starting with [your first agent](https://docs.agentloops.dev/tutorials/first-agent/):
  [docs.agentloops.dev](https://docs.agentloops.dev/)
- The source, visible for reference (all rights reserved): [github.com/alexec/Agents](https://github.com/alexec/Agents)

If something does not work, open an issue on GitHub. I read every one.
