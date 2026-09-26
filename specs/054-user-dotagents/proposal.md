# User-level dotagents

A proposal, not a spec yet. Projects already get the dotagents layout (`DotAgents.apply`,
5f9b974), with `.agents` as the one real copy and links only where a known agent needs
them. This does the same one level up, for the person: `~/.agents` holds the skills and
instructions that follow them into every project and every agent.

## What is on this Mac today

| Place | What is there | Who put it there |
|---|---|---|
| `~/.agents/skills/` | find-skills, grill-me, grill-with-docs, grilling | the `skills` CLI (vercel-labs), which also writes `~/.agents/.skill-lock.json` |
| `~/.grok/skills/<name>` | one symlink per skill, `-> ../../.agents/skills/<name>` | the same CLI |
| `~/.claude/skills/` | only `synced/` — claude.ai's synced skills, with a `.bucket-…` marker | Claude Code, managed |
| `~/.cursor/skills-cursor/` | Cursor's bundled skills, with a `.sync-manifest.json` | Cursor, managed |
| `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md` | nothing | — |

Two things follow. `~/.agents` is already a convention in the wild, with a tool that
writes to it, so we join it rather than invent one. And Claude does not read
`~/.agents/skills`: none of those four skills is offered in a Claude session here, and the
only mention of `~/.agents/skills` in Claude 2.1.282 is inside its importer, not its loader.

## The layout

    ~/.agents/
      AGENTS.md          instructions for every agent, in every project
      skills/<name>/     the person's skills — the one real copy
      personas/          as in a project

    ~/.claude/CLAUDE.md          -> ../.agents/AGENTS.md
    ~/.claude/skills/<name>      -> ../../.agents/skills/<name>     (one link per skill)
    ~/.codex/AGENTS.md           -> ../.agents/AGENTS.md
    ~/.grok/AGENTS.md            -> ../.agents/AGENTS.md            (if Grok reads it; see below)

The one real difference from a project: **per-skill links, not a folder link.** A project's
`.claude/skills` is ours to replace with a link; `~/.claude/skills` is not, because
`synced/` lives in it and belongs to claude.ai. Linking each skill inside it is also exactly
what the `skills` CLI already does for Grok, so the two tools produce the same shape and do
not fight.

## Rules, carried over from the project layout

- **Nothing the person wrote is lost.** A real `~/.claude/CLAUDE.md` with no
  `~/.agents/AGENTS.md` moves across and is linked back. A real skill folder in
  `~/.claude/skills/<name>` moves into `~/.agents/skills/<name>` when that name is free.
  Where both sides hold something different, both are left alone.
- **Managed folders are never touched:** `~/.claude/skills/synced`, anything with a
  `.bucket-*` or `.sync-manifest.json`, `~/.cursor/skills-cursor`, `.skill-lock.json`.
- **Only our own links are removed.** A link we would remove is one that points into
  `~/.agents/skills/` and whose target is gone. A link the person deleted is not put back
  (record what was placed, as `laidOutAt` does for projects).
- Each step is its own attempt, logged and carried past.

## When it runs

A project is laid out once. The home folder cannot be, because skills keep arriving —
`npx skills add`, or the person dropping a folder in. So:

1. **At daemon start**, reconcile: every skill in `~/.agents/skills` has its link in each
   runtime that needs one; dangling links of ours are removed.
2. **Before each runtime session is made** (where `layOutOnce` runs now), the same
   reconcile — cheap, a directory listing — so a skill added a minute ago is there for the
   next agent. No file watcher needed.

## Which runtimes need links

This is the part to verify, by probe rather than by reading binaries: put a throwaway skill
and a line in `~/.agents/AGENTS.md` on a scratch `HOME`, start each runtime over ACP, and ask
it what skills and instructions it has.

Probed 2026-09-26; see [research.md](research.md) R1.

| Runtime | Skills from `~/.agents/skills` | User instructions | Link needed |
|---|---|---|---|
| Claude | no | `~/.claude/CLAUDE.md` | skills per skill, CLAUDE.md |
| Codex | yes | `~/.codex/AGENTS.md` | AGENTS.md |
| Grok | yes | `~/.grok/AGENTS.md` (also reads Claude's and Cursor's) | AGENTS.md |
| Cursor | yes | none on disk | none |
| Copilot | yes | `~/.copilot/copilot-instructions.md` | copilot-instructions.md |
| Gemini | not probed | not probed | none until probed |

The table becomes the `links` list, as in `DotAgents`, keyed by runtime.

## Where the code goes

`DotAgents` grows a second entry point, `applyToHome()`, sharing `place`, `attempt` and the
move-then-link rule. The home guard in `apply(to:)` stays, so a project can never be the
home folder. Servers (037) get the same reconcile from the Linux `agentsd`, on the box's own
home; copying the Mac's `~/.agents` to a server is a separate, later question.

## Decided (Alex, 2026-09-25)

1. **Skills and instructions both.** Per-skill links into `~/.claude/skills` (and any other
   runtime that needs them), and `~/.claude/CLAUDE.md` / `~/.codex/AGENTS.md` linked to
   `~/.agents/AGENTS.md`.
2. **Existing Claude skills are adopted:** a real folder in `~/.claude/skills/<name>` moves
   into `~/.agents/skills/<name>` when the name is free and is linked back; clashes are left
   alone.
3. **Next: spec it**, with the runtime probe on a scratch `HOME` as part of the work.

4. **MCP servers and plugins too, in this spec** (widened later the same day).
   `~/.agents/mcp.json` is handed to every agent the app starts in its session request — no
   runtime's own config is written, so a CLI run by hand does not get them. Plugins live in
   `~/.agents/plugins`, handed to each runtime the way the probe finds it takes them.

Still open: whether Settings ▸ Agents shows a "Your skills" list naming which agent sees
which skill — settle that UX before the machinery.
