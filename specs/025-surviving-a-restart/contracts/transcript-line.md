# Contract: the line a question leaves when nobody answered it

One new sentence in the record, written by the daemon, read by every build of the app that
has ever existed.

---

## The entry

```json
{
  "id": "…",
  "at": "2026-09-24T11:40:01.900Z",
  "kind": { "runtimeNote": { "_0": "Nobody answered this question before the agent ended." } }
}
```

An existing kind with new wording, not a new kind. The wording is a constant on
`RuntimeNote`, beside `stoppedWithDaemon`, so it is written in one place and recognised in
one place.

## Why an existing kind

A `TranscriptEntry.Kind` this build does not know decodes as `unrecognised`, is kept in the
record, and is **drawn as nothing**. For a line whose entire purpose is to be read back in
six months, that is the wrong failure: the build that cannot draw it is exactly the build
whose reader is left wondering what happened to the question.

A `runtimeNote` is drawn by every build back to 001. It is also already the app's own
voice — which is FR-017 — where the nearest alternative, `permissionAnswered`, renders as
"You chose …" and would attribute to the person a choice they never made.

## Where it goes

Immediately after the `permissionAsked` or `elicitationAsked` entry it closes, and
**before** the `stateChanged` entry recording the ending (FR-015). Position is what says
which question it is about; the line does not name one.

A transcript therefore reads:

```
Asked: Write hello.txt
Nobody answered this question before the agent ended.
This agent was working when the daemon stopped, so it stopped too.
Stopped — the daemon went
```

## When it is written

| Cause | What the daemon knows | Source of truth |
|---|---|---|
| The runtime process exits | Exactly which questions were pending | `pendingPermissions`, `elicitations` |
| The person stops the agent | Exactly which questions were pending | the same two |
| The daemon restarts | That the agent was holding one | the agent's state before recovery |

The third is the one worth spelling out. After a restart the pending dictionaries are
empty — they died with the daemon — so the daemon cannot enumerate the questions. It does
not need to. `waitingOnUser` is the state a held permission or form puts an agent into,
and `recover()` already reads and keeps that state. One line is written for an agent found
in it.

## When it is not written

- The question was answered — `permissionAnswered` or `elicitationAnswered` is already the
  line that closes it.
- The question was declined or cancelled by the person — same.
- The runtime withdrew its own form — `withdrawElicitation` already appends a cancelled
  entry, and has since it was written.

Nothing may write both. A question gets exactly one closing line.

## What it must not become

It must **not** be added to `RuntimeNote.isPassing`. That set names the three notes the
chat drops once something follows them — "Starting Claude…", "Picked the conversation back
up.", "This agent was working when the daemon stopped". Each is true of a moment and false
after it. This one is true forever, and a reader scrolling back a month is precisely who
it is for.
