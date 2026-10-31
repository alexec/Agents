---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Start a session on Auto, choose which runtimes Auto uses and in what order, and read or change what each value is on each runtime.
---

# Use Auto

**Auto** is a runtime choice that is not a runtime. On Auto, the app picks the runtime when
the session starts, and gives that runtime its nearest setting for each value you chose. Use
it when you do not want to set the model, the mode and the sandbox again for each runtime,
or when one of your accounts runs out.

## Before you start

- At least one runtime installed and signed in. See [Sign a runtime in](sign-a-runtime-in.md).

## Start a session on Auto

1. Click **New session** in a folder (or press ⌘N).
2. Click the runtime above the prompt. **Auto** is the first item. Its line says the runtime
   it picks now, such as **Picks Claude now**. On a new install, Auto is already chosen.
3. Under the prompt, choose the values:
   - **Permission mode**: **Plan**, **Ask**, **Approve for me** or **Bypass Permissions**.
   - **Sandbox**: **Default sandbox**, **Runtime sandbox** or **No sandbox**.
   - **Model**: **Fast**, **Balanced** or **Smart**.

   Each value in a menu says what it is on the runtime Auto picks now, such as **Sonnet on
   Claude**. On Auto there is no **Permission requests** pill: **Approve for me** and
   **Bypass Permissions** say yes to each request, and the other two values give a card.
4. Type the prompt and send it. The header of the session says **Auto · Claude**: Auto, and
   the runtime it picked. The session stays on that runtime.

On iPhone and iPad, the form has **Runtime** (**Auto (Claude)**), **Model** (Fast, Balanced,
Smart), **Permission mode** and **Sandbox** rows.

Auto picks the first runtime in your order that is included, installed, signed in, not out,
and can give every value you chose. It tries a rate-limited runtime after all the others.
A helper that an Auto session starts with no runtime is on Auto too, and Auto picks again.

## Choose the runtimes and their order

1. Open **Settings ▸ Agent Runtimes ▸ Auto** (on the web page: **Settings ▸ Agent Runtimes ▸
   Auto**, under Machines).
2. Under **Runtimes**, turn **Include** off for a runtime that Auto must not use. Each row
   says the state of the runtime now: **Available**, **Rate limited**, **Out**, **Not signed
   in** or **Not installed**.
3. Drag a runtime to a new place (on iPhone, tap **Edit**; on the web page, use **↑** and
   **↓**; on the Mac, **Move Up** and **Move Down** are also in its menu). Auto tries the
   runtimes from the top.

The order and the switches are the same on the Mac, the Remote and the web page. The Mac
sends them to each of your machines.

## Read and change the mappings

Under **Mappings** there is one table for each field: **Model**, **Permission mode**,
**Permission requests** and **Sandbox**. Each cell is the runtime's own setting for that
value, with a mark:

- **auto-mapped**: the app's default for that value.
- **nearest safer**: the runtime has no exact match, so the cell gives the agent less access,
  never more. The note says why, such as "nearest safer: no plan mode".
- **Not possible**: the runtime cannot give that value with less access. Auto does not use
  that runtime when a session asks for that value.
- **yours**: you chose it. **Reset** puts the app's default back.
- **no longer offered** (with ⚠︎): the runtime check found that the runtime does not offer
  this model or mode now. Auto does not use that runtime for that value until you choose
  another setting.

To change a cell, click it and choose one of the runtime's own settings. The app does not
refuse a setting that gives more access: you chose it. The mapping applies to every agent
that uses the value, on Auto or on a named runtime.

On iPhone, the tables show one runtime at a time: choose the runtime, and its values are rows.

## If it doesn't work

- **The prompt stays in the box, with a line such as "Claude: out; Codex: not signed in".**
  No included runtime can take the session with the values you chose. The line says why for
  each runtime. Include another runtime, sign one in, or choose other values.
- **The Auto chooser says "No runtime included".** Every runtime is turned off on the Auto
  page. Turn one on.
- **The session ran out.** See [Keep going when a runtime runs out](keep-going-when-a-runtime-runs-out.md):
  an Auto session offers **Continue on** the next runtime.

## Related

- [Choose a runtime, model and mode](choose-runtime-model-mode.md)
- [Runtimes ▸ Auto](../reference/runtimes.md#auto)
- [Workflow triggers and actions](../reference/workflows.md): `runtime: auto`
