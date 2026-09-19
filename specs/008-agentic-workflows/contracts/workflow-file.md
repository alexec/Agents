# Contract: The workflow file

A workflow is one UTF-8 Markdown file at `<project>/.agents/workflows/<id>.md`. The file name without its extension is the workflow's identity.

The file opens with a YAML front-matter block and everything after it is the prompt. This is the format `FrontMatter.strip(_:)` in `AgentsKitCore` already understands, and workflow parsing reuses it rather than writing a second, subtly different one: `---` on the very first line is a fence around metadata, and `---` anywhere else is a horizontal rule the reader is entitled to see.

## Shape

```markdown
---
name: Morning build check
on:
  - schedule:
      at: [":00", ":30"]
      between: "09:00-18:00"
      days: [mon, tue, wed, thu, fri]
agent: new
---

Check whether the build is still green. If it isn't, find out what broke it
and tell me in one paragraph. Don't fix anything.
```

## Front-matter keys

| Key | Required | Type | Meaning |
|---|---|---|---|
| `on` | yes | list | The triggers. At least one entry. |
| `agent` | no | string | `new` (default), `standing`, `triggering` |
| `name` | no | string | Display name. Falls back to the file name. |

Any other top-level key is preserved verbatim and round-trips on rewrite. This is the `Agent.unknownFields` pattern, and it is what lets a file written against a newer version survive being edited by an older one.

## Triggers

Each entry in `on` is either a bare string or a single-key mapping.

### `schedule`

```yaml
- schedule:
    at: [":00", ":30"]          # required; only :00 and :30 are accepted
    between: "09:00-18:00"      # optional; defaults to all day
    days: [mon, tue, wed, thu, fri]   # optional; defaults to every day
```

Evaluated against the machine's current calendar and time zone every time, so a time-zone change or a DST boundary needs no rewrite and causes no double fire.

A value in `at` other than `":00"` or `":30"` is a parse error, not a rounding. The half-hour granularity is a deliberate floor: finer schedules invite workflows that fire faster than anyone can read the results.

### Agent lifecycle

Bare strings, each matching any agent in the same project:

| Trigger | Fires when |
|---|---|
| `agent-finished` | An agent ends a turn having completed its work |
| `agent-asked-permission` | An agent raises a permission request — while it is still outstanding |
| `agent-asked-form` | An agent raises an elicitation to be filled in |
| `agent-stopped` | An agent stops or fails without finishing |

### `workflow-completed`

```yaml
- workflow-completed            # any workflow in this project
- workflow-completed:
    id: morning-build-check     # that one
```

### Anything else

An entry naming a trigger this version does not know is kept with its keys and makes the workflow inert and listed as *not yet supported*. It is not an error and does not make the rest of the file unreadable. The triggers the spec defers — file and glob changes, git events, GitHub PR and CI — arrive as new names here and change nothing about existing files.

## Agent modes

| `agent:` | The prompt goes to |
|---|---|
| `new` | A fresh agent, every fire |
| `standing` | One long-lived agent belonging to this workflow, resumed each fire so it accumulates context. If that agent is gone, a fresh one is started and adopted. |
| `triggering` | The agent whose event fired this workflow. If there is no such agent, or it can no longer take a prompt, the fire is refused rather than substituted. |

An unrecognised value is *understood but not supported* — the workflow is listed with that problem and never fires. It is not a parse failure.

## The body

Everything after the closing `---`, verbatim, with a single leading blank line removed. It is sent as the prompt with no templating and no substitution.

For lifecycle triggers, the triggering agent's identity and what it did are supplied to the run alongside the prompt, so a `new` agent has something to act on without the author having to write a placeholder syntax.

An empty body is a parse error: a workflow with nothing to say is a scheduled no-op.

## Errors, and the difference between them

| Condition | Result |
|---|---|
| No front-matter fence on line 1 | Unreadable — listed with the problem, never fires |
| Front matter is not valid YAML | Unreadable |
| `on` missing or empty | Unreadable |
| Body empty | Unreadable |
| `at` contains a value other than `:00` / `:30` | Unreadable |
| A trigger name this version does not know | Listed, inert, *not yet supported* |
| An `agent:` value this version does not know | Listed, inert, *not yet supported* |
| An unknown top-level key | Accepted and preserved |

The line between the middle rows and the top ones is the whole point: a file we cannot read is broken, and a file we can read but cannot act on yet is a file from the future. They get different rows and different words.
