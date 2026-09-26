# Research: One Set of Skills and Instructions for Every Agent

## R1 — The runtime probe (FR-004)

**Method.** A scratch home at `/tmp/dotagents-probe/home` with one skill,
`~/.agents/skills/heron-probe` (its body says HERON-7), and `~/.agents/AGENTS.md` (OSPREY-3).
Each runtime was run headless (`-p` / `exec`) with `HOME` set to the scratch home, from an empty
git repo outside it, and asked, with no tools, to list its skills and every probe word in its
context. Sign-in came from the real Mac: Codex and Grok `auth.json` copied, Cursor's
`cli-config.json` copied and `~/Library/Keychains` linked, Copilot through `GH_TOKEN` from `gh`,
Claude through `CLAUDE_CODE_OAUTH_TOKEN` from its keychain item. The script is
[probe/run.sh](probe/run.sh); the prompt is [probe/ask.txt](probe/ask.txt). Nothing in the real
home was written.

Versions: Claude Code 2.1.282, codex-cli 0.156.1 (the app's pinned toolset), Grok 1.0.41,
cursor-agent 2026.09.10, Copilot CLI 1.0.89.

**Pass 1 — only `~/.agents`:**

| Runtime | heron-probe skill | OSPREY-3 |
|---|---|---|
| Claude | no | no |
| Codex | **yes** | no |
| Grok | **yes** | no |
| Cursor | **yes** | no |
| Copilot | **yes** | no |

**Pass 2 — a different probe word in each candidate personal-instructions file** (plus a link
`~/.claude/skills/heron-probe -> ../../.agents/skills/heron-probe`):

| File | Word | Read by |
|---|---|---|
| `~/.claude/CLAUDE.md` | KITE-1 | Claude, Grok |
| `~/.claude/AGENTS.md` | KITE-2 | Grok |
| `~/.codex/AGENTS.md` | EGRET-1 | Codex |
| `~/.grok/AGENTS.md` | EAGLE-1 | Grok |
| `~/.grok/GROK.md` | EAGLE-2 | nobody |
| `~/.cursor/AGENTS.md` | CRANE-1 | Grok |
| `~/.cursor/rules/personal.mdc` (alwaysApply) | CRANE-2 | nobody |
| `~/.cursor/rules/personal.md` | CRANE-3 | Grok |
| `~/.copilot/copilot-instructions.md` | ROBIN-1 | Copilot |
| `~/.copilot/AGENTS.md` | ROBIN-2 | nobody |

Claude offered heron-probe through the link. Grok made no tool call (checked in its JSON stream,
one turn), so it really does load Claude's and Cursor's personal files as well as its own.

**Pass 3 — the proposed layout, links only**, asking for a count of each word:

    ~/.claude/CLAUDE.md                 -> ../.agents/AGENTS.md
    ~/.codex/AGENTS.md                  -> ../.agents/AGENTS.md
    ~/.copilot/copilot-instructions.md  -> ../.agents/AGENTS.md
    ~/.grok/AGENTS.md                   -> ../.agents/AGENTS.md
    ~/.claude/skills/heron-probe        -> ../../.agents/skills/heron-probe

| Runtime | HERON-7 | OSPREY-3 |
|---|---|---|
| Claude | x1 | x1 |
| Codex | x1 | x1 |
| Grok | x1 | x1 (reads it through two links, reports it once) |
| Cursor | x1 | — |
| Copilot | x1 | x1 |

**Decision — the link table:**

| Runtime | Skills link | Instructions link |
|---|---|---|
| Claude | one per skill in `~/.claude/skills/` | `~/.claude/CLAUDE.md` |
| Codex | none (reads `~/.agents/skills`) | `~/.codex/AGENTS.md` |
| Grok | none | `~/.grok/AGENTS.md` |
| Cursor | none | none: it has no personal-instructions file (its User Rules live in its own settings) |
| Copilot | none | `~/.copilot/copilot-instructions.md` |
| Gemini | **unprobed** | **unprobed** |

**Gemini (046, merged to main after the probe)** is not installed on this Mac and has no
sign-in, so it was not probed. Its documented places are `~/.gemini/GEMINI.md` for personal
instructions and `~/.gemini/skills` for skills, possibly with `~/.agents/skills` as well. Until
the probe is run for it (T-probe in tasks), Gemini gets no links; that is safe, since a runtime
with no rule is left alone. `~/.gemini` exists here, made by Antigravity, so "folder exists"
cannot stand for "Gemini is installed"; installed means `RuntimeDiscovery` finds the runtime, for every runtime.

**Rationale.** Four of five read `~/.agents/skills` already, so Claude is the only skill link,
as in the project layout. No runtime reads `~/.agents/AGENTS.md`, so every runtime with a
personal file gets a link. Grok gets its own link although it also reads Claude's, so it does
not depend on Claude being installed; pass 3 shows no doubling.

**Limits.** The probe used each runtime's CLI, not its ACP adapter. The app starts Claude through
the Claude Agent SDK adapter, whose `settingSources` decide whether user settings (and so
`~/.claude/CLAUDE.md` and `~/.claude/skills`) load; the quickstart's walk confirms each runtime
through the app itself. Counts are the model's own report. Cursor's gap is recorded in the docs,
not worked around.

## R2 — Per-skill links, not a folder link

**Decision:** link each skill inside `~/.claude/skills`. **Rationale:** `~/.claude/skills/synced`
is claude.ai's, with a `.bucket-*` marker, so the folder is not ours to replace. The community
`skills` installer already links per skill (`~/.grok/skills/<name> -> ../../.agents/skills/<name>`),
so the two tools agree on shape. **Alternatives:** a folder link (rejected: moves `synced`);
copying (rejected: two copies drift).

## R3 — Which folders are adopted

**Decision:** only `~/.claude/skills/<name>` real folders and a real `~/.claude/CLAUDE.md` are
moved into `~/.agents`. **Rationale:** Alex's call was about Claude's folder, and Claude is the
only runtime that needs its skills linked back. The other runtimes' own skills folders hold
their makers' skills (Cursor's `skills-cursor`, Grok's bundled ones) and are not ours; a skill
someone put only in `~/.grok/skills` stays Grok's. Of the instruction files, only the first found
moves (FR-006), in the order Claude, Codex, Copilot, Grok; the others stay and are listed as
clashes. **Alternative:** adopt from every runtime (rejected: moves vendor-managed files).

## R4 — Which home, and when it is safe

**Decision:** the daemon lays out a home only when it is the standard root (the real app), or
when `AGENTS_PERSONAL_HOME` names one explicitly. A scratch root with neither does nothing to
any home. **Rationale:** FR-015 and the memory that vendor scripts already touched the real home
once. Tests pass the home in directly. **Alternative:** always use `$HOME` (rejected: every
scratch walk and test run would reach the real home).

## R5 — Remembering placed links (FR-009)

**Decision:** `personal-layout.json` in the daemon root: the set of link paths the app placed,
each with its destination. A link is placed only if its path is not in the set; a recorded link
that is gone from disk stays recorded (the person removed it) until its skill is gone too, when
the entry is dropped so that a skill added again is linked again. **Rationale:** mirrors
`laidOutAt`, per root, no litter in `~/.agents` (which the `skills` installer also writes).
**Alternative:** a marker file in `~/.agents` (rejected: another tool's folder).

## R6 — When it runs (FR-010) and what it costs (SC-005)

**Decision:** reconcile at daemon start and at the same point `layOutOnce` is called (before a
runtime session is made), serialised on the daemon actor. **Rationale:** two directory listings
and at most a handful of `lstat`s per skill per runtime; 100 skills is well under the 50 ms of
SC-005, measured by a test. No file watcher. **Alternative:** FSEvents (rejected: more machinery,
and nothing reads the links between sessions).

## R7 — Dangling links (FR-008)

**Decision:** in each runtime folder the app links into, remove a link whose destination
resolves inside `~/.agents/skills/` and no longer exists — whoever made it (the `skills`
installer's too). Nothing else is removed. **Rationale:** a link into the shared copy that
points at nothing is never wanted, and removing it is always safe.

## R8 — Servers

**Decision:** out of scope for this feature's build; the same reconcile runs on a Linux
`agentsd` later, on its own home. Recorded in the spec's Assumptions.

## R9 — The MCP and plugin probe, over ACP (FR-022)

**Method.** R1's scratch home, plus `run.sh setup-mcp`: a plugin in
`~/.agents/plugins/heron-plugin` (one skill, one command, one stdio MCP server, a
`.claude-plugin/plugin.json` and a `gemini-extension.json`), and a server named `shared` in each
runtime's own MCP config (`~/.claude.json`, `~/.codex/config.toml`, `~/.cursor/mcp.json`,
`~/.copilot/mcp-config.json`, `~/.gemini/settings.json`). Unlike R1, each runtime was started
**as the app starts it, over ACP** ([probe/acp.py](probe/acp.py), the `RuntimeCatalog` command
lines), and given in `session/new` three servers: `heron-mcp` (stdio), `egret-mcp` (http, served
by the probe) and `shared` (stdio, tagged as the request's copy). Claude and Grok were also given
the plugin the way the app hands over project plugins (`_meta.claudeCode.options.plugins`,
`_meta.pluginDirs`). **The evidence is the probe servers' own log**
([probe/mcp-server.py](probe/mcp-server.py)): a server that logged `tools/list` was offered to the
runtime. The model's own list was asked for too, and is not trusted: Grok and Codex both answered
"MCP: NONE" while their servers had logged `tools/list` (both load MCP tools lazily).

Versions as R1; Gemini is the app's toolset, 0.61.0.

| Runtime | `mcpCapabilities` | stdio from the app | http from the app | `shared` in both | Personal plugin |
|---|---|---|---|---|---|
| Claude | http, sse | yes | yes | the request's copy only | **yes**, by `_meta.claudeCode.options.plugins`: skill, command (offered as a skill) and its MCP server |
| Codex | http only (`sse: false`) | yes | yes | **its own config's**; the request's never started | **yes, after one `codex plugin add`**, see below: skill, command and MCP server |
| Grok | http, sse | yes | yes | the request's copy only | **partly**, by `_meta.pluginDirs`: skill and command, but the plugin's MCP server never started |
| Cursor | http, sse | yes | yes | **both started**; the model named the request's | **no**: not from `~/.cursor/plugins/local`, as a link or as a real copy |
| Copilot | http, sse | **no**: its log says `Rejecting non-http/sse MCP server "heron-mcp" from client` | yes | its own config's (the request's was stdio, so refused) | **no over ACP**; its CLI does load it, see below |
| Gemini | http, sse | unprobed | unprobed | — | its MCP server started from a `~/.gemini/extensions` link before `session/new` failed |

Gemini has no sign-in on this Mac ("Gemini API key is missing"), so no session opened; its
`initialize` and extension loading were seen, nothing after.

**Codex plugins.** Codex finds `~/.agents/plugins/marketplace.json` by itself and treats the
**home folder** as that marketplace's root, so a source must read `./.agents/plugins/<name>`
(`./plugins/<name>` fails with "missing plugin.json"). The plugin is then not loaded until
`codex plugin add <name>@<marketplace>`, which **copies** it into
`~/.codex/plugins/cache/<marketplace>/<name>/<version>`: an edit in `~/.agents` does not reach
Codex until the plugin is added again (or its version changes).

**Copilot plugins.** `copilot plugin marketplace add ~` (with `~/.claude-plugin/marketplace.json`
linked to the same index) and `copilot plugin install heron-plugin@personal` load it live, with
no copy, recorded in `~/.copilot/settings.json` as `extraKnownMarketplaces` and
`enabledPlugins`. `copilot -p` then offers the plugin's skill and command; `copilot --acp`
offers neither, and its log does not mention the plugin.

**What this settles for the spec.**

1. **FR-019 holds and matters**: Codex says `sse: false`, so an sse server must be left out for
   Codex.
2. **Copilot takes no stdio server from the app.** That is personal stdio servers and the
   app's own `agents` server too, which is why 036 saw Copilot agents with no app tools. FR-018
   (never write a runtime's config) and Story 6 ("every runtime") cannot both hold for Copilot.
   The ways out are: write `~/.copilot/mcp-config.json`, run stdio servers behind a local http
   endpoint the app serves, or accept the gap. **Decided by Alex, 2026-09-26: the local http
   bridge.** The app serves each stdio server over local http for Copilot. That writes no
   config, and gives Copilot agents the app's own `agents` tools too.
3. **The clash rule (FR-020) only orders what the app sends.** When the same name is in the
   runtime's own config, Codex and Copilot keep their own, Claude and Grok take the request's,
   and Cursor runs both. Settings should say which copy each runtime ends up with, not promise
   one order.
4. **Plugins reach three runtimes without writing their config**: Claude and Grok through
   session `_meta` (the app's existing project mechanism, pointed at `~/.agents/plugins`), and
   Gemini through a `~/.gemini/extensions/<name>` link. Grok does not start a plugin's MCP
   server, so a plugin's server should also go out in `mcpServers` for Grok. Codex needs a
   one-time `plugin add`, which writes its config and copies the plugin, so the app must add it
   again on every change. **Decided by Alex, 2026-09-26: the app re-adds it whenever the plugin's
   folder changes**, and the Plugins page says so. Cursor and Copilot-over-ACP are not reachable today.
5. **Only the log shows what a runtime got**, so the Settings view (FR-024) should report
   what the app sent and what each runtime is known to do with it, not ask the model.
