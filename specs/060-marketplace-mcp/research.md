# 060 · Research

Everything below was checked on 2026-09-26 against the live
[MCP Registry](https://registry.modelcontextprotocol.io) (`/v0` and `/v0.1`, same data) and
against the code 054 and 059 already shipped. Probes were `curl` only. Nothing was written to
disk. Spec decisions on secrets and project `mcp.json` are already locked
([spec.md](spec.md) · Decided).

## R1 · Search: `/v0/servers?search=&version=latest`

**Decision**: search with `GET https://registry.modelcontextprotocol.io/v0/servers?search=<q>&version=latest`.
No key. Results are shown in the registry's order. The app waits 300 ms after the last
keystroke, as 059 does. A query shorter than 2 characters is answered with an empty list and
no call.

**Findings**: the response is `{servers:[{server, _meta}], metadata:{nextCursor, count}}`.
Each `server` has `name` (reverse-DNS, e.g. `io.github.github/github-mcp-server`),
`description`, `version`, optional `title`, `packages[]` and/or `remotes[]`. `_meta` carries
`io.modelcontextprotocol.registry/official` with `status` and `isLatest`. Searching
`version=latest` returns one row per server. Pagination is by `cursor`; the sheet loads the
first page only in this slice (enough for a typed query).

**Quality**: there is no install count and no ranking. Search is a substring of the name.
`github` does not put GitHub's own server first; Smithery remotes dominate early pages. That is
why frame B shows the verified publisher on every row and a **known** mark for publishers on
the app's short list (R8), and why nothing is re-ranked.

**Alternatives**: calling each publisher's own site. Rejected — the registry is the one public
index the spec names.

## R2 · Detail: `/v0/servers/{name}/versions/latest`

**Decision**: open a row with
`GET /v0/servers/{url-encoded-name}/versions/latest`. The slash in the name is percent-encoded
(`io.github.github%2Fgithub-mcp-server`). `/v0` and `/v0.1` both answer 200 for the same path.

**Findings**: returns the full `server` object for that version. Used for frame C. Search
rows already carry packages and remotes for many servers, but detail is still fetched so the
sheet shows exactly what the registry has today, and so a future version pin has one place to
go.

## R3 · Turning a registry entry into an `mcp.json` entry

**Decision**: offer every way the registry lists that this Mac can run, and write one entry.

| Registry | Written as | Needs on the Mac |
|---|---|---|
| `remotes[].type` `streamable-http` / `http` | `{ "type": "http", "url", "headers" }` | nothing |
| `remotes[].type` `sse` | `{ "type": "sse", "url", "headers" }` | nothing |
| `packages[].registryType` `npm` | `{ "command": "npx", "args": ["-y", "<id>@<ver>"], "env" }` | `npx` |
| `packages[].registryType` `pypi` | `{ "command": "uvx", "args": ["<id>==<ver>"], "env" }` | `uvx` |
| `packages[].registryType` `oci` | `{ "command": "docker", "args": ["run", "-i", "--rm", …, "<id>"], "env" }` | `docker` |

- `runtimeHint` of `npx` / `uvx` / `docker` / `dnx` is a hint only; `registryType` decides.
- `mcpb` and `nuget`/`dnx` are not offered in this slice.
- Package version is pinned (`@ver` / `==ver` / image tag). A missing version uses the
  registry entry's `version`.
- Docker args: `-i --rm`, then each `runtimeArguments` name/value pair in order, then the
  image identifier. Variable placeholders in those values are rewritten to `${NAME}` (R4).
- The short name written under `mcpServers` is the registry `title` put through a slug (lower
  case, non-alnum → `-`), or the segment after `/` in `name` when there is no title. Clash
  rules are R7.

**Host call-out (frame B, C)**: for a remote, compare the URL's host to the publisher's own
host (GitHub org → `*.github.com` / `api.githubcopilot.com`; otherwise the domain of a
`com.<domain>` namespace, or the repository host). A different host is named on the row and in
detail, and any secret that host itself needs is listed under What it needs.

## R4 · Secrets: `~/.agents/secrets.env` and `${NAME}`

**Decision** (Alex, 2026-09-26): values live only in `~/.agents/secrets.env` (`KEY=value`, mode
0600). The server's entry holds `${NAME}` in `env`, `args` and `headers`. At session start the
daemon fills names in; a server with a name it cannot fill is left out of that session and
reported (FR-005).

**Mapping from the registry**:

- An `environmentVariables[]` item with `isSecret: true` → `${NAME}` in `env`, value typed
  into `secrets.env` under `NAME`.
- A non-secret env var → written as its default or the value the person typed, in `env`
  directly (not a secret).
- A remote `headers[]` item with `isSecret: true` and no `value` → header value is
  `${NAME}`, where `NAME` is the header name uppercased with non-alnum → `_` (so
  `Authorization` → `${AUTHORIZATION}`), unless the description clearly names a conventional
  token (`GITHUB_TOKEN`, `CONTEXT7_API_KEY`); then that name is preferred when the publisher
  is known (R8). Frame C for GitHub uses `GITHUB_TOKEN` as drawn.
- A header `value` of the form `Bearer {smithery_api_key}` → written as
  `Bearer ${SMITHERY_API_KEY}` (brace name uppercased).

**File format**: one `KEY=value` per line. A value may contain `=` and quotes; the first `=`
separates the key. Lines the app did not write are kept byte for byte. Never logged, never in
a read model, never sent to the phone (054 FR-023 holds).

**Alternatives**: Keychain. Rejected for this slice — Alex chose the file, matching Claude
Code's `${NAME}` in `.mcp.json`.

## R5 · Writing `mcp.json` in place

**Decision**: edit the `mcpServers` object in place. Keep every key the app did not add, in
the file's order. Write atomically (temp + rename). Refuse to write when the file cannot be
read (FR-008). Reuse `PersonalDotAgents.orderedKeys` and `parseServers` from 054; add a
writer that splices one entry.

A sidecar `<root>/catalog-mcp.json` records which names the app added (registry name, version,
chosen transport, destination). Remove and Replace only touch names the sidecar names.
Hand-written entries are never removed or overwritten (same rule as 059 FR-013).

## R6 · Project servers and approval

**Decision** (Alex): `<project>/.agents/mcp.json`, same shape as the person's. Read at session
start. Merge order becomes: **app → agent's chosen → project (approved) → personal → plugin
servers**. First of a name wins, so a project name beats the person's (FR-006).

A project server is a command that runs on this Mac. Approval is by a digest of the entry's
canonical JSON (sorted keys, no whitespace variance), stored in
`<root>/mcp-approvals.json` keyed by absolute project folder + server name — the same shape
as `PluginApprovalStore`. A server added from the sheet is approved as it is written. A pull
that changes the entry makes it wait again. Unapproved servers are listed and never handed to
a session.

Server projects (037) get no MCP section and are refused as a destination, as 059 R10 did for
skills.

## R7 · Clashes

**Decision**: same as skills.

- Sidecar names this destination's entry → Add becomes Replace (confirm).
- No sidecar, name taken → refuse; sheet says where it is and suggests the other destination
  (frame E / 059 E).
- Name free → Add.

## R8 · Publisher display and `known`

**Decision**:

- `io.github.<org>/…` → publisher label `<org> on GitHub`; known when `<org>` is in
  `KnownOwners` (059's list, case-insensitive).
- `com.<domain…>/…` or `ai.<domain…>/…` → label is the domain (`smithery.ai`); known when the
  registrable domain's first label matches a KnownOwner, or when the domain is on a short
  extra list: `github.com`, `modelcontextprotocol.io`.
- Otherwise show the namespace as-is; not known.

It is a mark, not a gate (look gate).

## R9 · Filling `${NAME}` at session start

**Decision**: after reading personal and project files, and before `SessionServers.plan`,
walk each server's `env`, `args` and `headers` string values. Replace `${NAME}` from
`secrets.env`. If any required reference is missing, drop that server and record the missing
name for Shared / the project page (frame A, D). Do not start it with an empty string.

Optional vars the person left blank are omitted from `env`/`headers` rather than sent empty.

## R10 · Scratch roots and tests

**Decision**: `secrets.env` and both `mcp.json` files resolve through
`StoreLocations.personalHome` and the project folder. A scratch root without
`AGENTS_PERSONAL_HOME` has no personal destination (sheet hides You). Tests and walks never
read `$HOME`. Registry calls go through `URLSession` with
`AGENTS_TEST_MCP_REGISTRY_URL` pointing at a fixture server
(`specs/060-marketplace-mcp/walk/fixture-server.py`).

## R11 · Reach dots

**Decision**: reuse 054's reach for the transport that will be written. A runtime that cannot
take that transport is struck before Add (frame C), as Shared already draws. Copilot + stdio
still works via the bridge; Copilot + sse that the handshake rejects is struck.

## R12 · Extending 059's sheet

**Decision**: one sheet, kind switch **Skills | MCP servers**. Search and detail branch on
kind. Destination (`Add to`) is shared. Offline / clash copy is shared, with "the MCP
Registry" in place of skills.sh. New daemon methods are `catalog/search` with a `kind` (or a
sibling `mcp/search` — see contracts): prefer extending `catalog/search` with
`kind: "skills" | "mcp"` so the sheet has one call. Detail / add / remove for MCP are
`mcp/preview`, `mcp/add`, `mcp/remove`, `mcp/set-secret`, `mcp/list`, `mcp/approve` —
control-only, never in `deviceMethods` or `agentMethods`.

**Why not overload `catalog/preview`**: a skill preview stages files; an MCP preview builds a
JSON entry and a secret list. Separate methods keep the contracts readable.
