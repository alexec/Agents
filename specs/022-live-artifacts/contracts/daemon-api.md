# Contract: `artifact/write`, and the turn note

## Request `artifact/write`

Sent by a window when the person's edit on the page is due to be saved.

```json
{ "agentID": "<uuid>", "path": "/abs/path/doc.md", "text": "<whole document>" }
```

**The daemon**
1. Refuses if the agent is not here (`noSuchAgent`).
2. Refuses if `path` is outside `agent.folderScope`, with the scope's own refusal sentence.
3. Writes `text` to `path` atomically, UTF-8, creating the file if it is not there.
4. Computes `PassageChange.between(previous, text)` where `previous` is what was on disk
   before the write, and appends one `ArtifactEdit` per changed passage to the agent's note,
   coalescing by `path` + `lines`.
5. Replies `{}`.

No broadcast: every window's `FolderWatch` sees the write and re-reads, which is the same
path an agent's write takes, so the page cannot treat the two differently by accident.

**Errors**: `noSuchAgent`, `invalidParams` (scope, path not absolute), and a plain
`internalError` with the file-system message when the write fails — surfaced on the page as
"Could not save: …" beside the passage, with the draft kept.

## The turn note

Appended in `beginTurn` as a text block after the person's words, only when the agent's
note is non-empty, then the note is cleared. Not recorded in the transcript. Wording, from
`Briefing.artifactEdited(_:)`:

> Since your last turn I edited `/abs/path/doc.md`. Lines 12–15 now read:
>
> ```
> <the passage as written>
> ```
>
> Work from what is there now; do not restore what you wrote before.

Several passages: one "Lines a–b now read:" block each, in document order. More than 20:
the first 20, then "…and more. Read the file before changing it."

## Why not a `person/edited` notification to other windows

There is nothing for them to do that the folder watch does not already do. If a second
window has the same page open it re-reads and re-renders like any other change.
