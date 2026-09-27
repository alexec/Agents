# Feature Specification: Search the MCP Registry and Add Servers to You or a Project

**Feature Branch**: `agents/060-marketplace-mcp`

**Created**: 2026-09-26

**Status**: Draft. The two decisions below are Alex's (2026-09-26). The look gate is next:
[look/](look/README.md), frames A–E.

**Input**: the next slice of 059 ("I'd like the user to be able to search and install skills,
plugins, and MCPs … add these to their project or user config"). 059 did skills. This slice
does MCP servers from the [official MCP Registry](https://registry.modelcontextprotocol.io),
through the same sheet. Plugins come after.

## Decided

1. **Secrets live in `~/.agents/secrets.env`.** It is one file in the person's home, readable
   only by them (mode 0600) and never committed. `KEY=value`, one per line.
   - A server's config never holds a secret's value, only its name, as `${GITHUB_TOKEN}`. That
     is the syntax Claude Code already uses in `.mcp.json`.
   - The daemon fills the names in from `secrets.env` when an agent starts, for both your own
     servers and a project's.
   - Values are never shown again after they are typed. They are never logged, never sent to
     the phone and never put in a read model (054's FR-023 holds).
2. **A project's servers go in `<project>/.agents/mcp.json`**, beside `.agents/skills` and
   `.agents/plugins`, in the same shape as `~/.agents/mcp.json`.
   - The app reads it when an agent starts in that project and hands its servers to every
     runtime, as it does the person's.
   - A runtime run by hand outside the app doesn't see it, as with `~/.agents/mcp.json`.
   - Claude Code's own root `.mcp.json` is left alone, so Claude never gets a server twice.

Also settled, following precedent rather than asked:

3. **A project's servers wait for approval.** A project server is a command that runs on the
   person's Mac. It arrives with a `git pull` or a clone, so a new or changed one is kept out of
   every session until the person approves it on the project page. It is approved by a digest
   of its entry, the way a project plugin and a workflow file already are (S2). One the person
   added from the sheet is approved as it is added.

## Why this feature exists

Adding an MCP server today means finding it, working out its command or URL, and writing JSON
by hand in `~/.agents/mcp.json`, with the API key pasted into the same file. A project has no
place for servers at all. The registry already lists servers with their packages, transports
and the variables and secrets they need, so the app can do all of that. It shows exactly what
will run before anything is written, and keeps secrets out of any file that might be shared.

## Scope

- **In:**
  - searching the registry;
  - a preview of what would run;
  - adding to You or to a project, with its secrets going to `secrets.env`;
  - the project's `.agents/mcp.json`, read at session start and waiting for approval;
  - a project page section for servers;
  - Remove;
  - setting a missing secret.
- **Later:** updates. The registry has versions, but a pinned `npx pkg@ver` changing under the
  person is its own question. Plugins come after that.
- **Out:**
  - the Remote (iOS) app;
  - servers on remote hosts;
  - OAuth sign-in flows beyond what the runtime itself does for an http server;
  - registries other than the official one.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Find a server and add it for every agent you start (Priority: P1)

In Settings ▸ Shared ▸ MCP servers the person chooses **Add server…** (frame A). The same
sheet as for skills opens on **MCP servers** (frame B). They type "github" and see matching
servers. Each shows its publisher (the registry-verified namespace), a description, and how it
runs: *remote*, *npx*, *uvx* or *docker*. They open one (frame C) and see:
- the exact command line or URL that will run;
- the host a remote one runs on;
- the variables it needs, with fields for the secrets;
- which runtimes can take it.

They type the token and choose **Add to ~/.agents**. The server's entry goes into
`~/.agents/mcp.json` with `${GITHUB_TOKEN}`, the value goes into `~/.agents/secrets.env`, and
the next agent they start has the server's tools.

**Independent test**: on a scratch root with a scratch home and a stand-in registry, search,
open, fill the secret and add. Check `mcp.json` holds `${NAME}` and no value, `secrets.env`
holds the value with mode 0600, and a started agent's `session/new` has the server with the
value filled in.

**Acceptance scenarios**:
1. **Given** a query, **When** results come back, **Then** each shows the publisher namespace,
   the description, the latest version and how it runs. Duplicate versions of one server show
   once.
2. **Given** a server with both a package and a remote, **When** its detail opens, **Then** the
   person chooses which (Run with: npx / docker / remote), and the detail shows the exact
   command or URL for that choice.
3. **Given** a remote whose URL is on another host than the publisher's own (for example
   `server.smithery.ai`), **When** its detail opens, **Then** that host is named, and so is any
   key the host itself needs.
4. **Given** required secrets, **When** a field is empty, **Then** Add is not offered. Once
   added, the value is written to `secrets.env` and never displayed again.
5. **Given** a secret name already in `secrets.env`, **When** the detail opens, **Then** the
   field says "set" and can be left as it is or replaced.
6. **Given** the server added, **When** an agent starts on a runtime that takes that transport,
   **Then** it has the server. A runtime that can't take it (Copilot and a remote over sse, for
   example) is shown as struck in the dots before adding, as 054 draws reach.

### User Story 2 - Add a server to a project (Priority: P1)

The project page gets an **MCP servers** section after Skills (frame D). **Add server…** there
opens the sheet set to the project. The server's entry goes into `<project>/.agents/mcp.json`
with `${NAME}` for its secrets, and the values go into the person's own `secrets.env`, never
the project. The line under the heading says the file is committed and that each person
supplies their own secrets.

**Acceptance scenarios**:
1. **Given** a project server added from the sheet, **Then** `.agents/mcp.json` has it with only
   `${NAME}` references, it is approved, and every agent then started in the project has it.
2. **Given** a server that arrived by `git pull`, **Then** it is listed as **Waiting for your
   OK** with the exact command it runs, and no session gets it until **Approve**.
3. **Given** a project server whose secret isn't in the person's `secrets.env`, **Then** its
   row says which name is missing and offers **Set…** (frame E). Sessions start without that
   server, rather than with an empty key.
4. **Given** the same server name for You and the project, **Then** the project's is the one
   agents in that project get, as with skills.

### User Story 3 - Remove a server, and set a secret (Priority: P2)

A server the app added shows its registry source and version, and offers **Remove**. A secret
can be set or replaced from the server's detail or from a missing-secret row (frame E). Remove
takes the entry out of `mcp.json`; the secret stays in `secrets.env` unless no other server
names it and the person ticks "also forget the secret".

### Edge cases

- **`mcp.json` can't be read.** Add is refused, and the file is never overwritten.
- **Hand-written entries of the person's own.** They are kept byte-for-byte, and so is the key
  order. Only the added server's entry changes.
- **A server name already taken.** The same rule as skills: the app replaces only what it added
  (recorded in its sidecar), and one the person wrote is never touched.
- **A value in `secrets.env` that contains `=` or quotes.** It is stored and read back exactly.
  A line the app didn't write is kept as it is.
- **A secret named in an entry but missing from `secrets.env`.** That server is left out of the
  session, with a note in Settings ▸ Shared and on the project page, rather than started with
  an empty value.
- **A scratch root.** `secrets.env` and every file are in the scratch home only.

## Requirements *(mandatory)*

- **FR-001**: The sheet has a kind switch, **Skills | MCP servers**. MCP search uses the
  registry's `/v0/servers?search=&version=latest`, shown in the registry's order.
- **FR-002**: Each result shows:
  - the publisher (the verified namespace, `io.github.<org>` shown as `<org> on GitHub`,
    `com.<domain>` as the domain);
  - the description;
  - the version;
  - the ways it runs.

  **known** marks a publisher on the app's short list.
- **FR-003**: The detail shows the exact command line (package, version pinned) or URL, the
  host a remote runs on, every variable with its description, and which are secrets.
- **FR-004**: Secrets are written to `~/.agents/secrets.env` (mode 0600, created if missing).
  The server's entry holds only `${NAME}`. No value appears in any log, event, read model or
  phone message.
- **FR-005**: At session start the daemon fills `${NAME}` in `env`, `args` and `headers` from
  `secrets.env`. A server with a name it can't fill is left out of that session and reported.
- **FR-006**: `<project>/.agents/mcp.json` is read at session start. Its servers are merged
  after the app's own and ahead of the person's; a name in both goes to the project. Each is
  approved by digest before any session gets it.
- **FR-007**: A project page lists the project's servers, with waiting ones first,
  **Approve**, **Set…** for a missing secret, and **Remove** for ones the app added.
- **FR-008**: `mcp.json` is edited in place, keeping everything the app didn't add byte for
  byte, and is written atomically. An unreadable file is never written.
- **FR-009**: Everything the network sees is the query and the registry entry asked for.
- **FR-010**: A scratch root's writes stay in its scratch home.

## Docs *(mandatory)*

- `docs/how-to/add-an-mcp-server-from-the-registry.md`: add.
- `docs/how-to/share-skills-across-agents.md`: change. `secrets.env` and `${NAME}`, and point
  to the new how-to.
- `docs/reference/settings.md`: change. MCP servers gains Add server… and Remove.
- `docs/explanation/projects-hosts-worktrees.md`: change. A project's servers, approval, and
  whose secrets they use.

## Assumptions

- The registry's `/v0` API stays open without a key, as it was on 2026-09-26.
- The registry's namespace check (GitHub org ownership for `io.github.*`, DNS for reverse-domain
  names) is the publisher signal. It carries no install counts, so there is no popularity to
  sort by.
- `npx`, `uvx` and `docker` are offered only when found on the Mac. A server with no way to run
  here says so.
