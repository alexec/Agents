# Contract: The "Docs" Section in a Feature Spec

This section is added to `.specify/templates/spec-template.md` straight after `## Success Criteria`:

```markdown
## Docs *(mandatory)*

<!--
  Which pages on the docs site (docs/) this feature adds or changes, so they are written
  with the feature rather than after it. One line per page. If the person using the app
  will see no difference, write "None" and why.
-->

- `docs/how-to/<task>.md` — add: <what it covers>
- `docs/reference/<thing>.md` — change: <which entries>
```

or:

```markdown
## Docs *(mandatory)*

None — <reason, e.g. "internal test fix; nothing the user sees changes">.
```

**Rules**:
- Paths are under `docs/` and name the section folder, so the Diataxis section is decided at spec time.
- `/speckit-tasks` turns each line into a task in the feature's polish phase.
- A spec written before this feature has no Docs section and is not changed retroactively.
