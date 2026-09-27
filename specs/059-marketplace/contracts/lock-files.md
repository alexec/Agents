# Contract: the lock files and the sidecar

These are the `skills` CLI's files (vercel-labs/skills 1.7.0), written in its own shape so each
tool reads what the other wrote (research R5, SC-005). The app adds **no** key of its own to
either of them.

## `~/.agents/.skill-lock.json` (personal)

The path is `$XDG_STATE_HOME/skills/.skill-lock.json` when `XDG_STATE_HOME` is set in the
daemon's environment, otherwise `<personalHome>/.agents/.skill-lock.json`.

```json
{
  "version": 3,
  "skills": {
    "swiftui-expert-skill": {
      "source": "avdlee/swiftui-agent-skill",
      "sourceType": "github",
      "sourceUrl": "https://github.com/avdlee/swiftui-agent-skill.git",
      "skillPath": "skills/swiftui-expert-skill/SKILL.md",
      "skillFolderHash": "4b58ee6b6270e512f22054e0eb7e0d719b43128d",
      "installedAt": "2026-09-26T15:10:00.000Z",
      "updatedAt": "2026-09-26T15:10:00.000Z"
    }
  },
  "dismissed": {},
  "lastSelectedAgents": []
}
```

- `skillFolderHash` is the git **tree** SHA-1 of the skill's folder at the commit.
- `installedAt` is kept on replace. `updatedAt` is set to now. Timestamps use ISO 8601 with
  milliseconds and `Z`, as JS `toISOString` writes them.
- Every other top-level key, and every other skill's entry, is written back exactly as read.
- It is written with two-space indentation. The CLI writes no trailing newline, so neither does
  the app.
- If `version` is below 3, or the JSON can't be parsed, the app writes nothing and reports
  `lockUnreadable`. The CLI would treat that file as empty and wipe it; the app does not.

## `<folder>/skills-lock.json` (project)

```json
{
  "version": 1,
  "skills": {
    "swiftui-pro": {
      "source": "twostraws/swiftui-agent-skill",
      "sourceType": "github",
      "skillPath": "swiftui-pro/SKILL.md",
      "computedHash": "…64 hex…"
    }
  }
}
```

- Only `version` and `skills` are written, and skill keys are sorted, as the CLI does. It is
  written with two-space indentation and a trailing newline.
- `computedHash` is SHA-256 over each file in the installed folder, in `localeCompare` order of
  the relative path (with `/` as the separator). For each file the relative path's UTF-8 bytes go
  in first, then the file's bytes. `.git` and `node_modules` folders are skipped. It is checked
  by golden tests produced with `node`.
- This file is committed with the project like any other. The app leaves it unstaged.

## `<root>/catalog-skills.json` (the app's sidecar)

```json
{
  "version": 1,
  "skills": {
    "personal/swiftui-expert-skill": {
      "commit": "b24e68a965dc4b5bd2cc41dc60c094a26a9379ce",
      "committedAt": null,
      "treeSHA": "4b58ee6b6270e512f22054e0eb7e0d719b43128d",
      "catalogue": "skills.sh",
      "addedAt": "2026-09-26T15:10:00Z"
    }
  }
}
```

It lives in the daemon's root, so a scratch root has its own. Losing it costs only the "Taken at"
line and one API call on the next update check.
