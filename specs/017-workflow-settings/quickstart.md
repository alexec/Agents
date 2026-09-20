# Quickstart: Workflow Settings

Four checks, in order of how much they prove. The first two are seconds and settle the logic; the
third is the one that matters — that a workflow asking for a mode it cannot have starts nothing at
all; the fourth is the page, which has no view tests and is checked by hand once.

## Prerequisites

```sh
xcodegen generate
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
```

Section 4 needs one runtime signed in and on the path — `claude`, `copilot`, `grok` or
`cursor-agent` — because the settings menus are built from what a runtime actually advertised, and
nothing is advertised until one has run in that folder once.

---

## 1. The settings themselves (seconds)

```sh
swift test --package-path Packages/AgentsKit --filter WorkflowSettings
```

Expect: a file with no settings resolving to nothing sent; a named mode resolving under the option id
the runtime advertised rather than the string `"mode"`; a mode that is not on offer coming back
refused with the offered values named; and a `triggering` workflow's summary saying nothing about a
mode it will never apply.

The one to read if it fails is `aModeTheRuntimeDoesNotOfferIsRefusedAndNotSubstituted`. Everything
else here is convenience. That one is the feature.

---

## 2. The file editor (seconds)

```sh
swift test --package-path Packages/AgentsKit --filter FrontMatterEdit
```

Expect: a key added just inside the closing fence; a value changed with the comment after it intact;
an indented `model:` under a trigger left alone; the body returned byte for byte, including a body
with its own `---` rule in it; and a document with no front matter refused rather than given one.

This is the only thing in the app that writes into a file a person wrote. A failure here is not a
failing test, it is the app having moved something in somebody's repository that nobody asked it to
move.

---

## 3. A workflow that must not change files (a minute)

```sh
swift test --package-path Packages/AgentsKit --filter WorkflowSettingsFlow
```

Against the fake runtime, which advertises `configOptions` and records every `setConfigOption` it is
sent. Four claims:

- A workflow naming `permission-mode: plan`, against a runtime offering it, reaches the runtime —
  asserted on the fake's own record of what it was told, not on what we meant to tell it.
- A workflow naming a mode the runtime does **not** offer starts **no agent**. Assert the agent count
  before and after are equal, and that the workflow's last outcome is `.settingRefused`. A test that
  only checks the refusal was recorded would pass while an agent ran in the wrong mode.
- A workflow naming a runtime that is not in the catalog is refused rather than started on another.
- A workflow with no settings takes the old path: no draft is made, and the agent starts as it always
  did.

---

## 4. Opening one, and changing it (five minutes, by hand)

Run the app against a project you do not mind a file appearing in.

**Write one, by hand**, at `<project>/.agents/workflows/build-check.md`:

```markdown
---
name: Build check
on:
  - schedule:
      at: [":00", ":30"]
agent: new
---

Check whether the build is green. Say so in one line. Don't fix anything.
```

Then, in order:

1. **It appears** on the project page within a few seconds, under *Workflows*. Its row says when it
   next runs.
2. **Click the row.** The workflow opens — name, what it is, the settings, and the whole prompt.
   Back returns to the project page. (P1, P5, P8)
3. **Set its permission mode** to a read-only or plan mode. Look at the file in an editor: one line
   is different, it sits just inside the closing `---`, and nothing else has moved — not the
   comment, not the order, not the prompt. (FR-020, FR-022)
4. **Look at the row.** It now says the mode, without anything being opened. (FR-027)
5. **Run it now** and open the agent it started. Its options show the mode it was started in.
   (FR-006)
6. **Break it**: change the file by hand to `permission-mode: nonsense`. Run it now. No agent starts;
   the row says what is wrong and names the modes the runtime does offer; the row and its icon go
   red, because nothing resolves this until somebody fixes it. (FR-008, FR-012)
7. **Open it again.** The mode control shows `nonsense`, marked as one this runtime does not offer,
   with what it does. This is the page earning its place: the row says something is wrong, the page
   says what to put instead. (FR-024)
8. **Set `agent: triggering`** in the file. The row's sentence loses the mode clause entirely; the
   page shows the three controls disabled under one line saying why. (FR-011)
9. **Archive it.** It still opens, still shows its prompt, and offers Restore. (P1, P7)

**Then the one an agent writes.** In a chat on that project:

> Set up a workflow that checks the dependencies for security advisories every weekday morning. It
> must not change anything.

Expect a file with a permission mode in it, and a reply that names the mode in words rather than
quoting YAML. (FR-028, FR-029, SC-007)

---

## What none of this proves

That `plan` on one runtime promises what `plan` promises on another. It does not, this app never
claims it does, and the value in the file is the runtime's own word passed through untouched. What
is proved here is that the word reaches the runtime, or that nothing runs.
