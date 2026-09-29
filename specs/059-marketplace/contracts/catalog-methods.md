# Contract: the catalogue methods

New daemon methods for the Add sheet, the project section and Shared ▸ Skills. Every one of them
is **control-only**: the app window's signed connection can call them. None is in
`deviceMethods` or `agentMethods`, so a phone, an agent's helper or a stranger gets the usual
refusal (`ConnectionRole`). Types are in [data-model.md](../data-model.md).

`destination` is always `{"kind":"personal"}` or `{"kind":"project","folder":"/abs/path"}`.

## `catalog/search`

```json
→ { "query": "swiftui" }
← { "results": [ { "id": "avdlee/swiftui-agent-skill/swiftui-expert-skill",
                   "name": "swiftui-expert-skill", "owner": "avdlee", "repo": "swiftui-agent-skill",
                   "skillID": "swiftui-expert-skill", "installs": 32978, "known": false } ] }
```

- Results come in skills.sh's order. Non-GitHub sources are dropped (R1). The daemon never pads
  the list or re-ranks it.
- A query shorter than 2 characters is answered `{results: []}` without calling skills.sh.
- Errors are shown in the sheet as frame E: `{"error": {"kind": "unreachable", "host": "skills.sh"}}`.
  An error never comes back as an empty list.

## `catalog/preview`

```json
→ { "result": { …CatalogResult… }, "destination": { "kind": "personal" } }
← { "preview": { "previewID": "…", "name": "swiftui-expert-skill", "description": "…",
                 "skillPath": "skills/swiftui-expert-skill/SKILL.md",
                 "commit": "b24e68a965dc4b5bd2cc41dc60c094a26a9379ce", "committedAt": null,
                 "treeSHA": "4b58ee6b…", "computedHash": "…",
                 "files": [ { "path": "SKILL.md", "bytes": 5120, "runnable": false } ],
                 "skillMarkdown": "---\nname: …", "totalBytes": 612345,
                 "problems": [], "destinationState": { "free": {} } } }
```

- Fetches and stages once (R3). Calling it again for the same result makes a new preview at the
  then-current HEAD.
- `destinationState` is for the destination given. The sheet asks again, with no new fetch, when
  Add to changes: `catalog/destination-state {previewID, destination}` returns only that field.
- This call never writes outside `<root>/catalog-staging/`.

## `catalog/destination-state`

```json
→ { "previewID": "…", "destination": { "kind": "project", "folder": "/Users/…/Agents" } }
← { "destinationState": { "unmanaged": { "path": "/Users/…/Agents/.agents/skills/review" } } }
```

## `skills/add`

```json
→ { "previewID": "…", "destination": { … }, "replace": false }
← { "skill": { …ManagedSkill… } }
```

- `replace` must be `true` when the state is `managedOther` or `sameSkill(update: true)`, and is
  refused otherwise. An `unmanaged` destination is always refused with
  `{"error":{"kind":"unmanaged","path":…}}` (FR-013).
- The order of steps (FR-009) is:
  1. Stage.
  2. Move the old folder, if there is one, to the Trash.
  3. Rename the staged folder into place.
  4. Write the lock file.
  5. Write the sidecar.

  If step 3 fails, the old folder is put back from the Trash. If step 4 fails, the new folder is
  moved to the Trash and the old one put back. So after any failure the destination is as it was
  (SC-003).
- For a project, `.agents/skills` is created if missing, and `.claude/skills` is linked through
  `DotAgents` if missing (R7). Nothing is staged or committed in git.
- The preview is used up whether it succeeds or not.

## `skills/list`

```json
→ { "destination": { "kind": "project", "folder": "…" } }
← { "skills": [ { "name": "run-app", "description": "…", "folder": "…", "managed": null } ] }
```

For the project section (D). The personal list stays in `personal/shared`, whose `Skill` gains
`managed`.

## `skills/check-updates`

```json
→ { "destination": { … } }
← { "updates": { "find-skills": { "available": { "commit": "…" } } } }
```

- Checks each `source` at most once an hour (FR-018). A newer answer comes from the cache.
- The app calls it when Shared ▸ Skills or a project page appears, and never on a timer.

## `skills/update-preview`

```json
→ { "destination": { … }, "name": "find-skills" }
← { "preview": { …SkillPreview… }, "changes": { "added": [], "changed": ["SKILL.md"], "removed": [] },
    "edited": false }
```

Stages the new commit and lists what would change compared with the installed folder. It feeds
`skills/add` with `replace: true`. When `edited` is true, the app asks a second time (FR-019).

## `skills/remove`

```json
→ { "destination": { … }, "name": "find-skills" }
← { "trashedTo": "/Users/…/.Trash/find-skills" }
```

- Refused for a folder with no lock entry.
- Moves the folder to the Trash, then drops the lock entry and the sidecar entry. 054's `sweep`
  removes Claude's link at the next reconcile, which runs before the next session start.

## Logging

`catalog: search "<query>" → N | preview o/r/skill @ <commit7> (snapshot n, raw m, tarball?) |
add <name> → personal|<project name> | remove … | update-check o/r → current|available`.

File contents, `gh` output and tokens are never logged.
