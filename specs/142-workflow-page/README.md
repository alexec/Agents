# #142 Workflow page: every attribute that matters

A design note for the look, before any depth is built. The issue is
[#142](https://github.com/alexec/Agents/issues/142); its table lists every attribute and
which client shows it today. This note says where each one goes, what can be changed from
the page, and recommends answers to the questions the issue leaves open.

Alex approved the Mac look and these answers on 2026-10-03. The depth, the Remote and the web
page are built on this branch (screenshots below).

## The page answers four questions, in this order

1. **Is it running, and if not, why?** The status, under the title.
2. **What does it do?** The prompt, with who receives it and how they run.
3. **When does it run?** Triggers and cooldown.
4. **What has it done?** Last ran, and its recent runs.

The reader who opens a workflow is usually asking the first question, so that comes first,
in its own card, instead of one line in grey under the title.

## Where each attribute goes

| Group | Attribute | From | Where on the page | Editable here |
| --- | --- | --- | --- | --- |
| **Title** | Name | `name:` / file name | Title | No (the file's) |
| | Summary sentence | derived | Under the title, as today | — |
| | Run now / Approve, Enabled, Archive | app + `enabled:` `archived:` | Top right, as today | Yes, as today |
| **Status** (why it is or isn't running) | Archived | `archived:` | Status card, first line | Bring Back |
| | File problem | parse | Status card (red), with the raw file under it, as today | No |
| | Waiting for approval, new or changed | app | Status card, with Approve on the title line | Approve |
| | Waiting its turn behind 3 others (#132) | `overLimit == .project` | Status card: which limit and what to do | No |
| | Over the limit of 10 | `overLimit == .total` | Status card: which limit and what to do | No |
| | Off, and **where that came from** | `offReason` + `enabled:` | Status card: "Off: its file says `enabled: false`" / "Turned off here" / "An agent turned it off" / "Written by an agent" | The switch |
| | On | `enabled:` | Status card: "On", and whether the file says so or says nothing | The switch |
| | Running now | app | Status card, with **Open the agent** | — |
| | Cooling down / holding a fire | app | Status card | — |
| | Next run | app | Status card, last line | — |
| | Last outcome (refusal) | app | Status card, when it was a refusal | — |
| **What it does** (the form, shaped like the prompt bar) | File path | file | Top left pill (Finder), as today | No |
| | Runtime | `runtime:` | Top right menu, as today | Yes |
| | **Agent mode** | `agent:` | A row of its own above the prompt: "Starts a new agent each run" / "Sends to its standing agent" / "Resumes the agent that triggered it" | No (see Q2) |
| | **Standing agent** | `WorkflowSummary.standingAgentID` | Same row, for `standing`: its name as a link, or "Started on the next run" when there is none or it has gone | — |
| | Prompt | body | Middle, as today | No |
| | Permission mode | `permission-mode:` | Bottom left pill, as today | Yes |
| | Model / effort / options | `model:` `effort:` `options:` | Bottom right pill, as today | Yes |
| | **Labels** | `labels:` | A row under the pills: the label tag input sessions use (#50, #133) | Yes (see Q1) |
| **When it runs** | Triggers, filters, scope, next time | `on:` | Triggers card, as today | No |
| | Cooldown, when it ends, held fire | `cooldown:` | Under the triggers, as today | Yes, as today |
| **The rest of the file** | **Unknown keys** | `unknownFields` | Its own small card, only when there are any: "This version does not understand:" and each key with its value, monospaced | No |
| **History** | Last ran / caused by (event link) | app | Top of History | — |
| | Recent runs | app | Under it, as today | — |

Bold rows are the issue's gaps.

## Editable versus read-only

The rule the page already follows, kept: **what the workflow is** (its triggers, its prompt,
its agent mode, its name) is the author's and is read-only here; **how much it may do and
whether it runs** (runtime, permission mode, model, effort, options, labels, cooldown,
Enabled, Archive) is editable, each control writing its one key in the file through the
daemon, as the settings do today.

## Unknown keys

Shown only when the file has any, after the triggers, in a card titled
**From a later version**: "This version does not understand these lines in the file. They
are kept as they are when the page changes it." Each key and its value as YAML, monospaced,
read-only, a line each; a nested value shows as one line of JSON. Grey, not tinted: a key
from the future asks nothing of the reader (the same rule `WorkflowProblem.needsAPerson`
uses).

## Recommended answers to the open questions

1. **Labels editable on the page?** Yes, with the same tag input sessions use, writing
   `labels:` in the file like the other settings. The daemon's settings writer does not write
   `labels:` yet, so that is the one piece of depth this needs on the Mac. The look shows the
   field disabled until then.
2. **Agent mode editable?** No, read-only. Changing `agent:` changes what the workflow is
   (who receives the prompt, whose context it builds), like changing its triggers, and the
   page does not edit those. It is said as its own row, in words, not only inside the summary.
3. **Standing agent: what to show?** Its name as a link to open it, and "Started on the next
   run" when there is none yet or it has gone. `WorkflowSummary` needs a `standingAgentID`
   from `WorkflowStore` for this to be exact; the look stands in with the newest agent the
   workflow started.
4. **Where does `offReason` go?** In the status card, as the first sentence about being off,
   with where the switch's position came from. The heading keeps only the summary sentence,
   so the reason is not said twice.
5. **Over a limit: what to say?** Which limit (3 waiting in this project, or 10 approved
   across every project) and the remedy, from `WorkflowLimit.sentence` and `.remedy`, in the
   status card. The triggers' "no next time" stays as the short form.
6. **Unknown keys: keys only, or with values?** With values, read-only. A key without its
   value does not tell the reader what the file says.
7. **The web page: read-only to start?** Yes. The web page shows every attribute read-only
   (runtime, permission mode, model/effort/options, labels, cooldown, agent mode, unknown
   keys), keeping its existing Run now, Approve, Enabled and Archive. Editing the settings from
   the web is a later parity issue, not `web: by design`.
8. **The Remote: editable like the Mac?** Yes. It already edits runtime, permission mode and
   options; it gains the status card, agent mode, standing agent, labels and unknown keys in
   the same order as the Mac.

## What is built

- **Labels** (Q1): `WorkflowSettingsRequest.labels` writes `labels:` through
  `FrontMatterEdit.set(_:toList:in:)`, held to `SessionLabelPolicy` and written only when they
  changed. Left out means left alone, so a phone or page from before this cannot remove them by
  saving a mode. A one-line `[a, b]` stays one line; a block of `- a` lines stays a block, an
  item that stays keeping its line and comment. The Mac and the Remote edit them with
  `LabelTagField`.
- **Standing agent** (Q3): `WorkflowSummary.standingAgentID` is the agent `WorkflowStore`
  keeps, while it is here and not archived (the same test the fire makes); `nil` reads
  "Started on the next run".
- **Status lines**: `Shared/UI/WorkflowStatus.swift`, so the Mac and the Remote say the same
  lines; the web page's `workflowStatusLines` is its port.
- **The Remote** (Q8): Run now or Approve, Enabled, then Status, What it does (agent mode,
  standing agent, prompt), Settings, Labels, From a later version, Recent runs.
- **The web page** (Q7): every attribute read-only, in the same order, with Run Now or Approve,
  Enabled and Archive / Bring Back (`workflows/approve` and `workflows/archive` added to the
  page's methods). Editing the settings from the web is #162.

## Screenshots

From a run-app root with three workflows, after one run of Nightly review:

- `shot-on.png` / `web-on.png`: on, standing (its agent linked), labels, a cooldown and an
  unknown key.
- `shot-off-by-file.png` / `web-off-by-file.png`: `enabled: false` in the file.
- `shot-awaiting-approval.png` / `web-awaiting-approval.png`: changed since it was approved,
  `agent: triggering`.
- `web-approved.png`: the same on the page after Approve.
