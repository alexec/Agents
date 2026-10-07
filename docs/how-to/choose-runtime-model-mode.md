---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Choose the runtime, model, mode and effort an agent runs with, and read how full its context is and what it has cost.
---

# Choose a runtime, model and mode

Every agent runs on one runtime, such as Claude or Codex, and each runtime offers its own
choices: which model, how much it asks before acting (its mode), and sometimes how hard it
thinks (effort). This guide sets them for a new agent, changes them for one that is
running, and reads the meter that says how full its context is.

## Before you start

- At least one runtime installed and signed in. See [Sign a runtime in](sign-a-runtime-in.md).

## Steps

**For a new agent**

1. Unfold the project in the sidebar and click **New session**, the first row under it (or press ⌘N).
2. Click the runtime above the prompt, on the right, and choose one. A runtime that cannot
   be used says why under its name, such as **Needs signing in**.
3. Under the prompt, the runtime's own choices appear as capsules. Their names and values
   are the runtime's, so they differ from one to the next. Usually:
   - the mode, on the left, such as **Ask for approval** or **Full access** for Codex, or
     a plan or read-only mode;
   - on the right, the model, and effort where the runtime has it.

   Click one and choose. A runtime that offers no choices, such as Cursor, shows none.

   Cursor and Grok also have no permission-mode capsule under the prompt: set **Default**
   or **Always-approve** for each in **Settings ▸ Agent Runtimes**. Cursor's **Agent**,
   **Plan** and **Ask** stay as they are; they are not that permission setting.

   Beside the mode is the command sandbox, such as **Sandbox: runtime controlled** or
   **Sandbox off**. It is the app's, not the runtime's list, and it is separate from the
   mode: the mode says when the agent asks you, the sandbox says what its commands can
   reach. Choose **Use runtime default** to follow **Settings ▸ Agent Runtimes**, or **On**
   or **Off** for this agent only. For Codex, **Off** is **Full access** and turns its
   approval prompts off too; the mode capsule changes with it. A runtime the app cannot
   change shows its state only; hover over it for why.
4. Type the prompt and send it. The agent starts with what you chose.

   On iPhone and iPad, the start form has **Runtime**, **Sandbox**, **Mode**, **Model** and
   **Effort** rows instead.

**For an agent that is running**

1. Open its conversation.
2. Change the mode, model or sandbox in the same capsules under the prompt. A mode or model
   change applies from the agent's next step, a sandbox change from its next turn, never
   in the middle of a command; the runtime itself cannot be changed. To carry the work on with
   another runtime, start a new chat there and ask it to continue this one; see
   [Keep going when a runtime runs out](keep-going-when-a-runtime-runs-out.md).

**Read the meter**

Above the prompt of a running agent, beside its name, is what it has cost so far, and a
ring where the runtime says how big its context is.

- The ring fills as the conversation fills the model's context. Hover over it for the
  numbers. A nearly full context is the most common reason an agent starts to forget or
  wander; start a new agent, or branch this one, before it fills.
- The cost is the runtime's own figure, never an estimate. It turns red when the agent is
  close to a spending limit; hover for how much is left. A runtime that reports no price
  says so, and no limit applies to it. See [Limit what agents spend](limit-spending.md).

A workflow sets the same choices in its file, with `runtime:`, `model:`, `effort:`,
`permission-mode:` and `options:`. See [Workflow triggers and actions](../reference/workflows.md).

## If it doesn't work

- **The runtime I want is not in the menu.** It is not installed on this Mac, or on the
  server the project is on. See [Runtimes](../reference/runtimes.md).
- **There is no ring.** The runtime does not say how big its context is.
- **"Claude's sandbox could not start" (or another runtime's) over a new agent's prompt.** The runtime
  cannot set up its sandbox on this computer or server. The prompt stays in the box;
  **Start without sandbox** sends it again with this agent's sandbox off. See
  [Answer a question or a permission request](answer-a-question.md).
