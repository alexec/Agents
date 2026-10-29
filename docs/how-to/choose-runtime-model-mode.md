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

1. Unfold the folder in the sidebar and click **New session**, the first row under it (or press ⌘N).
2. Click the runtime above the prompt, on the right, and choose one. **Auto** is the first
   item: the app picks the runtime when the session starts (see [Use Auto](use-auto.md)). A
   runtime that cannot be used says why under its name, such as **Needs signing in**.
3. Under the prompt, the pills use the same words on every runtime. Each pill shows only its
   value:
   - **Permission mode**, on the left: **Plan** (the agent reads and plans, and changes
     nothing), **Ask** (it asks before it changes things), **Approve for me** (it does not
     ask for normal changes in its folder) or **Bypass Permissions** (it never asks, even
     for a change outside its folder);
   - **Model**, on the right: **Fast** (the runtime's smallest quick model), **Balanced** (its
     usual model) or **Smart** (its most capable model). Effort follows the model: low for
     Fast, high for Smart.

   Each value in a menu says what it is on this runtime, such as **Sonnet on Claude**. The
   runtime's own choices, such as a fourth Claude mode or the effort, are under **⋯ Claude's
   own** in the same menu. When you choose one that is not a value, the pill says **Custom**.
   The values you chose stay when you change the runtime.

   Cursor, Grok and OpenCode also have a **Permission requests** pill under the prompt.
   Choose **Request cards** to be asked, with a card, before an action that needs permission,
   or **Yes to all** for the app to say yes to each permission request. Questions that are
   not permission still wait. The choice is for this agent only. The value from
   **Settings ▸ Agent Runtimes ▸ Cursor** (or Grok, OpenCode) is marked **follows Settings**.

   Beside the mode is the **Sandbox** pill: **Default sandbox** (the runtime's own settings
   decide), **Runtime sandbox** (the app turns the runtime's sandbox on) or **No sandbox**
   (commands run with your own access). It is the app's, not the runtime's list, and it is
   separate from the mode: the mode says when the agent asks you, the sandbox says what its
   commands can reach. The value from **Settings ▸ Agent Runtimes** is marked **follows
   Settings**; choose another for this agent only. For Codex, **No sandbox** is **Full
   access** and turns its approval prompts off too; the mode capsule changes with it. A
   runtime the app cannot change shows its fixed value; hover over it for why.
4. Type the prompt and send it. The agent starts with what you chose.

   On iPhone and iPad, the start form has **Runtime**, **Model** (Fast, Balanced, Smart),
   **Permission mode**, **Permission requests** for Cursor, Grok or OpenCode, and **Sandbox**
   rows, and the runtime's own choices under **⋯ <runtime>'s own**.

**For an agent that is running**

1. Open its conversation.
2. Change the permission mode, model or sandbox in the same pills under the prompt. A mode or model
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
`permission-mode:`, `permission-requests:`, `sandbox:` and `options:`. The values are the
same words in lower case: `runtime: auto`, `model: smart`, `permission-mode: plan`. See
[Workflow triggers and actions](../reference/workflows.md).

## If it doesn't work

- **The runtime I want is not in the menu.** It is not installed on this Mac, or on the
  server the folder is on. See [Runtimes](../reference/runtimes.md).
- **There is no ring.** The runtime does not say how big its context is.
- **"Claude's sandbox could not start" (or another runtime's) over a new agent's prompt.** The runtime
  cannot set up its sandbox on this computer or server. The prompt stays in the box;
  **Start without sandbox** sends it again with this agent's sandbox off. See
  [Answer a question or a permission request](answer-a-question.md).
