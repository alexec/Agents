---
name: competitor-check
description: Find what tools that run several coding agents at once shipped since the last report, compare it with what Agents does, file at most three gaps as competitor issues, and write the report to ~/.agents/reviews/competitors/. Build nothing. Use when the Competitor check workflow runs in a release (#1462), or when Alex asks for a competitor check.
---

# Competitor check

This is the method of the Competitor check workflow
(`.agents/workflows/competitor-check.md`). The workflow says what the method is for and
starts it. A person or an agent can also follow it by hand. Where it says that nobody is
at the keyboard, that is true only of a run of the workflow.

## Who to watch

Tools that run several coding agents at once: Conductor, the OpenAI Codex app, Sculptor
(Imbue), Superset, Parallel Code, Pragma, Codeg, Acepe, Nimbalyst, Claude Code's own
desktop, web and mobile apps, Cursor background agents and GitHub Copilot's agent
sessions. Add any new tool of this kind you come across, and say in the report that you
added it.

## Steps

1. Read the last report in `~/.agents/reviews/competitors/` (if any) so you only report
   what is new since then.
2. Search the web for each tool's changelog, release notes and launch posts since the last
   report (the past 30 days when there is none).
3. For each new feature, check whether Agents already has it: search `docs/`, `specs/`
   and the GitHub issues, open and closed (`gh issue list --state all --search …`).
4. Drop gaps the folder has set aside, such as new runtimes or App Store work.
5. Pick **at most three** gaps that users of those tools would expect from us. File each
   one with `gh issue create --label competitor --label enhancement`, after creating the
   `competitor` label if it does not exist yet. Each issue says which tool has the feature
   (with a link) and what Agents does today. Do
   not file a duplicate of an existing issue: if one already covers the gap, add a
   comment to it instead.
6. Write the report to `~/.agents/reviews/competitors/<YYYY-MM-DD>.md`. It lists each
   tool, what it shipped, whether Agents has it, the issues you filed, and the sources.

## Rules

- Never change the folder you start in: it is the shared checkout of `main`.
  Make no branches and no commits, and start no other sessions.
- When you mention Alex, name them. Write no bare "you".
- End with one sentence naming the issues you filed (or saying there were none) and the
  path to the report.
