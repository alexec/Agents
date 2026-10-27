# Feature Specification: Auto Runtime

**Feature Branch**: `agents/2658-auto-runtime-the-app-picks`

**Created**: 2026-10-27

**Status**: Approved by Alex, 2026-10-27 (with **Plan** in place of **Read-only**).

**Input**: GitHub issue #2658, "Auto runtime: the app picks the runtime, model and mode from
three model levels (Fast / Balanced / Smart)". Wireframe:
`~/.agents/product-owner/wireframes/2658-auto-runtime.html` on Alex's Mac.

## Why this feature exists

Each runtime has its own names for the model, the permission mode and the sandbox. When a
person changes the runtime, they must set all of these again, with new words. A workflow or a
persona that says `model: opus` or `permission-mode: acceptEdits` works on one runtime only.

This feature adds two things:

1. **One set of words for each field.** The same words apply on every runtime. No word is in
   two fields, so a pill under the prompt shows the value only.
2. **Auto**, a runtime choice that is not a runtime. On Auto, the app picks the runtime when the
   session starts, and maps each value to that runtime's nearest setting.

## The words

| Field | Values (a pill shows only the value) | Was |
| --- | --- | --- |
| **Runtime** | **Auto**, or the name of a runtime | the name of a runtime |
| **Model** | **Fast**, **Balanced**, **Smart** | each runtime's model names |
| **Permission mode** | **Plan**, **Ask**, **Approve for me** | each runtime's mode names |
| **Permission requests** (Cursor, Grok, OpenCode only) | **Request cards**, **Yes to all** | **Default**, **Always-approve** |
| **Sandbox** | **Default sandbox**, **Runtime sandbox**, **No sandbox** | **As configured by runtime** / **Runtime controlled**, **On**, **Off** |

What each value means, on every runtime:

- **Fast**: the runtime's smallest and quickest model that can do the work. **Balanced**: its
  usual model. **Smart**: its most capable model.
- **Plan**: the agent can read and plan, but cannot change files or run commands that
  change things. **Ask**: the agent asks before it changes things. **Approve for me**: the agent
  does not ask for normal changes in its folder.
- **Request cards**: each permission request is a card for the person. **Yes to all**: the app
  says yes to each permission request.
- **Default sandbox**: the runtime's own settings decide. **Runtime sandbox**: the app turns the
  runtime's sandbox on. **No sandbox**: commands run with the person's access.

The names in workflow, persona and `start_session` files are the same words in lower case with
hyphens: `auto`; `fast`, `balanced`, `smart`; `plan`, `ask`, `approve-for-me`;
`request-cards`, `yes-to-all`; `default`, `runtime`, `none`.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start a session on Auto (Priority: P1)

The person opens a new session. The runtime chooser shows **Auto** first. The person keeps
**Auto**, types a prompt and sends it. The app picks the first runtime in the person's order
that can do the work, and starts the agent there with the chosen model, permission mode and
sandbox.

**Why this priority**: This is the feature. Without it, nothing else in this spec has a use.

**Independent Test**: On a scratch set-up with Claude and Codex signed in, start a session on
Auto with **Balanced**, **Ask** and **Default sandbox**. The agent starts on Claude with
Claude's balanced model and Claude's ask mode. Mark Claude **Out**; the next Auto session
starts on Codex.

**Acceptance Scenarios**:

1. **Given** a new session, **When** the person opens the runtime chooser, **Then** **Auto** is
   the first item, and its subtitle names the runtime it picks now ("Picks Claude now").
2. **Given** Auto is chosen, **When** the person looks under the prompt, **Then** the pills show
   only their values, such as **Ask**, **Default sandbox** and **Balanced**, and there is no
   **Permission requests** pill.
3. **Given** Auto is chosen, **When** the person opens the Model pill, **Then** the menu header
   says **Model**, and each value says what it is on the runtime Auto picks, such as
   "Balanced: Sonnet 5 on Claude".
4. **Given** the first included runtime is **Out**, not signed in or not installed, **When** the
   session starts, **Then** Auto starts it on the next included runtime that can take it.
5. **Given** a rate-limited runtime is first in the order, **When** the session starts, **Then**
   Auto tries the other included runtimes first, and uses the rate-limited one only when no
   other can take the session.
6. **Given** no included runtime can take the session with the chosen values, **When** the
   person sends, **Then** the prompt stays in the box and a line says why, for each runtime in
   short ("Claude: out; Codex: not signed in; OpenCode: no Runtime sandbox"), with a link to
   Settings ▸ Agent Runtimes ▸ Auto.
7. **Given** an Auto session is running, **When** the person looks at its header, **Then** it
   says **Auto · Claude** (the runtime Auto picked).

---

### User Story 2 - The same words on every runtime (Priority: P1)

The person picks Codex, then Claude, then Cursor. On each, the pills use the same words. The
values that the person chose stay when the runtime changes, where the new runtime can give
them.

**Why this priority**: The issue decides that the new words replace the old ones on every
runtime (two sets of words for one field would confuse). Auto depends on the same words.

**Independent Test**: Start a session on Claude with **Smart** and **Plan**. Change the
runtime to Codex before sending. The pills still say **Smart** and **Plan**, and the menus
say what they are on Codex.

**Acceptance Scenarios**:

1. **Given** any runtime, **When** the person looks under the prompt, **Then** the pills are
   Permission mode, Sandbox and Model (and Permission requests on Cursor, Grok and OpenCode),
   each showing one of the values in "The words".
2. **Given** a runtime has more choices than the three values (for example a fourth Claude
   mode), **When** the person opens **⋯ Claude's own**, **Then** the runtime's own choices are
   there, and a choice that matches no value makes its pill say **Custom**.
3. **Given** a runtime that cannot change its sandbox, **When** the person looks at the Sandbox
   pill, **Then** it shows the fixed value (Cursor, Copilot, Grok: **Default sandbox**;
   OpenCode, Antigravity: **No sandbox**), cannot be changed, and says why on hover.
4. **Given** the person has not chosen a sandbox for this agent, **When** they open the Sandbox
   menu, **Then** the value from Settings ▸ Agent Runtimes has the mark **follows Settings**.
   There is no fourth value for "use the default".
5. **Given** a running agent, **When** the person changes the model or permission mode, **Then**
   the change applies on the same runtime from the agent's next step, as today.

---

### User Story 3 - Choose which runtimes Auto uses, and in what order (Priority: P2)

The person opens Settings ▸ Agent Runtimes ▸ Auto. They see each runtime with an **Include**
switch, a drag handle and its state now (Available, Rate limited, Out, Not signed in, Not
installed). They exclude Cursor and drag Codex above Claude.

**Why this priority**: Auto works with the shipped order. The person needs this to say which
accounts they want to spend first.

**Independent Test**: Exclude Claude, put Codex first; start an Auto session; it starts on
Codex. Restart the daemon; the order and the switches stay.

**Acceptance Scenarios**:

1. **Given** Settings ▸ Agent Runtimes, **When** the person opens it, **Then** **Auto** is the
   first item in the list of runtimes.
2. **Given** the Auto page, **When** the person turns **Include** off for a runtime, **Then** Auto
   does not start a session on it, also when every other runtime is out.
3. **Given** the Auto page, **When** the person drags a runtime to a new place, **Then** Auto
   tries the runtimes in the new order.
4. **Given** the Auto page on the Mac, **When** the person opens it on the Remote or the web
   page, **Then** it shows the same order and switches, and a change on one shows on the
   others.

---

### User Story 4 - See and change the mappings (Priority: P2)

On the same page, under **Mappings**, the person sees one table for each field: Model,
Permission mode, Permission requests and Sandbox. Each table has a row for each runtime and a
column for each value. Each cell shows the runtime's own setting for that value.

**Why this priority**: The person must be able to see what each word does on each runtime, and
to fix a mapping they disagree with. Without it, the auto-map is a black box.

**Independent Test**: In the Permission mode table, change Claude's **Approve for me** from
**Accept edits** to **Bypass permissions**. The cell says **yours** and has **Reset**. A new
Claude session with **Approve for me** starts in Bypass permissions. **Reset** returns it to
**Accept edits**.

**Acceptance Scenarios**:

1. **Given** the shipped app, **When** the person opens Mappings, **Then** every cell has a
   value marked **auto-mapped**.
2. **Given** a runtime has no exact match for a value, **When** the app maps it, **Then** it
   takes the nearest value that gives the agent **less** access, never more, and the cell says
   so ("nearest safer: no plan mode").
3. **Given** no safer value exists (for example **Runtime sandbox** on OpenCode), **When** the
   person looks at the cell, **Then** it says **Not possible**, and Auto skips that runtime when
   the session asks for that value.
4. **Given** the person clicks a cell, **When** they choose one of the runtime's own settings,
   **Then** the cell shows it, marked **yours**, with **Reset**. The app does not refuse a
   choice that gives more access; the person chose it.
5. **Given** the nightly runtime check finds that a runtime dropped a model or mode that a cell
   uses, **When** the person opens Mappings, **Then** the cell shows a warning, and Auto skips
   that runtime for that value until the table is updated or the person chooses another
   setting.
6. **Given** a mapping, **When** an agent starts on any runtime (Auto or not) with a value,
   **Then** it gets the same native setting the table shows.

---

### User Story 5 - Workflows, personas and helpers on Auto (Priority: P2)

A workflow says `runtime: auto`, `model: smart`, `permission-mode: plan`. It runs on the
first runtime Auto can use, with that runtime's smart model and plan mode. A helper started
with `start_session` from an Auto agent is also on Auto.

**Why this priority**: The issue counts workflows and personas in the reach. A workflow on Auto
keeps working when one account is out.

**Independent Test**: A workflow with the front matter above runs on Claude; with Claude out, it
runs on Codex, with Codex's plan mode (Read only).

**Acceptance Scenarios**:

1. **Given** a workflow, persona or `start_session` call with `runtime: auto` and the new
   values, **When** it starts, **Then** the daemon resolves the runtime and native settings as
   the prompt does.
2. **Given** a workflow with a runtime's own value (`permission-mode: acceptEdits`, `model: opus`),
   **When** it starts on that runtime, **Then** it works as today.
3. **Given** a workflow with `runtime: auto` and a runtime's own value, **When** the daemon reads
   it, **Then** it refuses the file with a line that says to use one of the new values.
4. **Given** an Auto agent starts a helper with no runtime, **When** the helper starts, **Then**
   it is on Auto, and Auto picks again (it may pick another runtime than the parent).

---

### User Story 6 - The Remote and the web page (Priority: P2)

The Remote and the web page offer the same things as the Mac: Auto in the runtime chooser, the
new words, the **Auto · Claude** header and the Auto page in Settings.

**Why this priority**: The three clients stay in step (AGENTS.md).

**Independent Test**: Start an Auto session from the iPhone form; it starts on the same runtime
the Mac would pick. Open Settings ▸ Agent Runtimes ▸ Auto on the web page; it shows the same
tables.

**Acceptance Scenarios**:

1. **Given** the iPhone or iPad new-session form, **When** the person opens it, **Then** it has
   the rows **Runtime** (**Auto (Claude)**), **Model** (a segmented control: Fast, Balanced,
   Smart), **Permission mode** and **Sandbox**, and **Permission requests** only for Cursor,
   Grok and OpenCode.
2. **Given** the web page, **When** the person starts a session, **Then** the chooser and pills
   are as on the Mac.
3. **Given** the Mappings tables on iPhone, **When** the screen is narrow, **Then** each table
   shows one runtime at a time, with its values as rows.

### Edge Cases

- **Gemini's own "Auto" model.** Gemini's model menu has an item called Auto. It stays behind
  **⋯ Gemini's own**; the model pill on Gemini shows **Custom** when it is chosen.
- **A model that needs a paid plan.** If a runtime's mapped model is not on the person's plan,
  the runtime cannot honour that value: Auto skips it, and the cell says why.
- **Codex's sandbox and mode are one setting.** Codex's **Full access** is both **Approve for
  me** and **No sandbox**. The Codex rows in the two tables keep this link: choosing
  **No sandbox** on Codex gives Full access, as **Off** does today.
- **Permission requests on Auto.** On Auto, **Approve for me** gives **Yes to all** and the other
  two give **Request cards**. There is no pill. On a named runtime, the pill stays.
- **The organisation requires a sandbox (#998).** An organisation policy that requires the
  sandbox takes priority over the chosen value, as today; Auto skips a runtime that cannot turn
  its sandbox on.
- **A helper of a sandboxed agent.** A helper cannot get **No sandbox** when the agent that
  started it is sandboxed, as today.
- **A server folder.** Auto picks from the runtimes on that server only, in the person's order.
- **Every runtime excluded.** The chooser shows Auto with "No runtime included", and send is off
  until the person includes one.
- **An existing agent.** An agent that started before this feature keeps its native settings.
  Its pills show the matching value, or **Custom**.
- **The runtime runs out during an Auto session.** The session stops as today, with a note. The
  note has one button, **Continue on Codex** (the next runtime Auto would pick), which starts a
  continuation there. Auto does not do this alone.

## Requirements *(mandatory)*

### Functional Requirements

**Words and values**

- **FR-001**: The app MUST show the values in "The words", and only those, in the model,
  permission mode, permission requests and sandbox pills of every runtime, on all three
  clients.
- **FR-002**: The runtime's own choices MUST stay available behind **⋯ <runtime>'s own**. A
  native choice that matches no value MUST make its pill say **Custom**.
- **FR-003**: Effort MUST follow the model level by default (Fast: low; Balanced: the runtime's
  default; Smart: high). A cell in the Model table MAY set a different effort. Effort stays
  under **⋯ <runtime>'s own**.
- **FR-004**: The wire (`Packages/Wire/daemon.schema.json`) MUST carry `auto` as a runtime
  choice, and the model level, permission mode, permission requests and sandbox values as
  enumerations.

**Auto**

- **FR-005**: **Auto** MUST be the first item in the runtime chooser on all three clients, and
  MUST be accepted as `runtime: auto` in workflows, personas and `start_session`.
- **FR-006**: The daemon (Go agentsd) MUST resolve Auto when the session starts: the first
  included runtime, in the person's order, that is installed, signed in, not **Out**, and can
  honour every chosen value. A rate-limited runtime MUST be tried after the others.
- **FR-007**: The daemon MUST record on the agent that it is an Auto agent, the runtime it
  picked, and the native model, mode, effort, permission requests and sandbox it gave.
- **FR-008**: An Auto agent MUST keep its runtime for the life of the session.
- **FR-009**: The chat header of an Auto agent MUST say **Auto · <runtime>**.
- **FR-010**: On Auto, **Permission requests** MUST follow the permission mode and MUST NOT be
  shown as a pill.
- **FR-011**: When no included runtime can take a session, the send MUST fail with a short
  reason for each runtime, and the prompt MUST stay in the box.
- **FR-012**: An agent with no runtime given that is started by an Auto agent MUST be on Auto.
- **FR-013**: Auto MUST be the default runtime for a new install. A person who has already
  chosen a default runtime MUST keep it.

**Settings**

- **FR-014**: Settings ▸ Agent Runtimes MUST have an **Auto** page with a **Runtimes** list
  (Include switch, order by drag, state now) and **Mappings** tables for Model, Permission
  mode, Permission requests and Sandbox.
- **FR-015**: The app MUST ship a default mapping for every runtime and value. Where there is no
  exact match, the default MUST be the nearest value that gives less access; where none exists,
  the cell MUST be **Not possible**.
- **FR-016**: The person MUST be able to override any cell with any of the runtime's own
  settings. An override MUST be marked **yours** and MUST have **Reset**.
- **FR-017**: The order, the Include switches and the overrides MUST be the person's, stored
  beside the sandbox defaults in the daemon's settings, and the Mac MUST send them to every
  machine, as it does the sandbox defaults (research R2).
- **FR-018**: The mappings MUST apply to every agent that uses the new values, on Auto or on a
  named runtime.
- **FR-019**: **Permission requests** MUST become a choice per agent. The Mac-wide value per
  runtime MUST become the default, shown in Settings, and marked **follows Settings** in the
  menu.

**Checks and safety**

- **FR-020**: The nightly runtime check MUST report a mapped model or mode that a runtime no
  longer offers. The cell MUST show a warning, and Auto MUST skip that runtime for that value
  until it is fixed.
- **FR-021**: The organisation's sandbox policy, and the rule that a helper of a sandboxed agent
  stays sandboxed, MUST apply to the mapped value as they apply today.
- **FR-022**: When an Auto session's runtime runs out, the note MUST offer one button that
  starts a continuation on the next runtime Auto would pick. Auto MUST NOT start it alone.

### Key Entities

- **Value**: one of the words in "The words", for one field.
- **Mapping**: for one runtime and one value, the runtime's own setting (model and effort,
  mode, permission answer or sandbox), and whether it is **auto-mapped**, **nearest safer**,
  **yours**, **Not possible** or has a warning.
- **Auto settings**: the person's order of runtimes, an Include switch for each, and their
  overrides of mappings.
- **Auto choice on an agent**: that the agent is on Auto, the runtime picked, and the native
  settings given.

### Default mappings (a first draft)

The plan step checks each name below against the runtime's own list. Model names change; the
table ships with the app and the nightly check keeps it true.

**Permission mode**

| Runtime | Plan | Ask | Approve for me |
| --- | --- | --- | --- |
| Claude | Plan | Default | Accept edits |
| Codex | Read only | Ask for approval | Approve for me |
| Gemini | Plan | Default | Auto-edit |
| Grok | Default (nearest safer: no plan mode) | Default | Default + Yes to all |
| Cursor | Plan | Agent + Request cards | Agent + Yes to all |
| OpenCode | Plan | Build + Request cards | Build + Yes to all |
| Copilot | the runtime's plan or read-only mode, or nearest safer | its ask mode | its auto-approve mode, if any |
| Antigravity | the runtime's plan or read-only mode, or nearest safer | its ask mode | its auto-approve mode, if any |

**Sandbox**

| Runtime | Default sandbox | Runtime sandbox | No sandbox |
| --- | --- | --- | --- |
| Claude | as configured | on | off |
| Codex | as configured | on (Ask or Approve for me) | off (Full access) |
| Gemini | as configured | Not possible | off |
| Grok, Cursor, Copilot | as configured (fixed) | Not possible | as configured (nearest safer) |
| OpenCode, Antigravity | none (fixed) | Not possible | none (fixed) |

Note: a fixed **Default sandbox** gives less access than **No sandbox**, so it is the nearest
safer value for it, with a note on the cell (research R5).

**Model**: Claude Fast = Haiku, Balanced = Sonnet, Smart = Opus; for the other runtimes, their
smallest, usual and largest models, chosen by the plan step from each runtime's list.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A person can start a session on Auto with three clicks or fewer after they type
  the prompt (no runtime-specific choices).
- **SC-002**: A person who changes the runtime of a new session does not need to set the model,
  mode or sandbox again in 100% of cases where the new runtime can honour the values.
- **SC-003**: The same workflow file with `runtime: auto` runs on at least two different
  runtimes with no change to the file.
- **SC-004**: Every one of the 8 runtimes × 14 values has a mapping, a **Not possible** or a
  warning; no cell is empty.
- **SC-005**: No auto-mapped cell gives an agent more access than the value says (checked by a
  test over the shipped table).
- **SC-006**: The Mac, the Remote and the web page pick the same runtime for the same session,
  because the daemon decides.

## Docs *(mandatory)*

- `docs/how-to/choose-runtime-model-mode.md` — change: the new words, Auto, **⋯ <runtime>'s
  own**, per-agent Permission requests.
- `docs/how-to/use-auto.md` — add: start on Auto, set the order, read and change the mappings.
- `docs/reference/runtimes.md` — change: a section on Auto and the default mapping table; the
  Grok, Cursor and OpenCode rows use **Request cards** / **Yes to all**.
- `docs/reference/workflows.md` — change: `runtime: auto` and the new values for `model:`,
  `permission-mode:`, `permission-requests:` and `sandbox:`.
- `docs/how-to/keep-going-when-a-runtime-runs-out.md` — change: the **Continue on <runtime>**
  button on an Auto session.
- `specs/071-web-remote/walks/parity/` — change: rows for Auto, the pills and the Auto page.

## Assumptions

- The issue's decisions (Alex, 2026-10-26, and the agent's **Decided** lines) stand.
- The four open questions in the issue take the recommended answers; see "Decided in this
  spec".
- v0.x takes breaking changes: the old sandbox and permission words go without a migration. A
  per-agent "Use runtime default" becomes no override.
- The daemon already knows each runtime's state (installed, signed in, Out, rate limited) and
  its live list of models and modes; Auto uses these.
- The Auto settings are per person, not per project or organisation. An organisation policy
  (#998) can come later.
- This is a large change. The plan may split it into PRs in this order: words and wire, daemon
  resolution, Mac, Remote, web, Settings page, nightly check.

## Decided in this spec

Decided: Auto is the default runtime for a new install; an existing default stays, because it
helps new people and changes nothing for existing ones. Alex can overrule.

Decided: when an Auto session's runtime runs out, Auto does not continue alone in v1; the note
offers one **Continue on <runtime>** button, because a new runtime reads the work again and costs
money. Alex can overrule.

Decided: **Permission requests** becomes a choice per agent, with the Mac-wide value as the
default in Settings, because every other field is per agent. Alex can overrule.

Decided: effort follows the model level, and a cell in the Model table can set it, because a
sixth field adds a pill for a small gain. Alex can overrule.

Decided: a workflow on a named runtime can still use the runtime's own values, and a workflow on
Auto must use the new values, because old workflows keep working and Auto cannot map a native
name from one runtime to another. Alex can overrule.
