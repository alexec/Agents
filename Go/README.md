# Go

The daemon (`agentsd`) and the control plane (`agents-control`), moved from Swift to Go
(#1134; the Swift ones went in #1314). One module, so the two share the wire types and the
control exchange. The Mac window, the Remote, `Shared/UI`, the web page, Agents Host and
`agents-relay` stay as they are.

| Path | What | Area |
|---|---|---|
| `wire/` | The wire types: `*_gen.go` made from `Packages/Wire/` by `scripts/wire.sh gen`, the meaning-types by hand | build |
| `cmd/wiregen/` | Makes `wire/*_gen.go` and `Web/src/protocol/generated.ts` from `Packages/Wire/` | build |
| `internal/buildinfo/` | The version and the implementation (`go`) | build |
| `cmd/agentsd/`, `internal/agentsd/` | The host daemon (#1136): `store/` is the root as the Swift host laid it out, `diskjson/` its encoding | hosts |
| `cmd/agentsctl/` | A client of a control plane for walks without the screen; not shipped | hosts |
| `cmd/agents-control/`, `internal/controlplane/` | The control plane | control-plane |
| `internal/controllink/` | Both sides of the host ↔ control plane exchange | control-plane |
| `internal/safe/` | Recover helpers: one panic never takes a host or the control plane down | build |
| `cmd/github-mcp/`, `internal/githubmcp/` | The `github` MCP server (#1232): the official github-mcp-server's tools, as a library, and the ci server's events | ci-server |
| `cmd/linear-mcp/`, `internal/linearmcp/` | The `linear` MCP server (#839): Linear's issue events, in github-mcp's shape (tools are Linear's own server's) | ci-server |
| `cmd/email-mcp/`, `internal/emailmcp/` | The `email` MCP server (#1780): one IMAP mailbox's new mail as `email.received`, and tools that read it; it never sends | email |
| `cmd/gitlab-mcp/`, `internal/gitlabmcp/` | The `gitlab` MCP server (#1629): merge requests, pipelines and issues on GitLab, tools and events on REST v4 | gitlab |
| `cmd/workspace-commands/`, `internal/workspacecommands/` | The command machine provider (#691, in Go since #1364): workspaces as shell commands and presets, an MCP server the control plane runs | workspaces |

## Building and testing

On the Mac, Go runs in a `golang` container (Go is not installed here); the caches are in
`~/Library/Caches/Agents-build/go`. Lease "build" first.

```sh
Go/scripts/go.sh vet ./...
Go/scripts/go.sh test ./...
```

CI's `go` job builds, vets and tests the module on Linux on any change under `Go/`, and
`scripts/select-test-suites.sh` runs no Swift suite or macOS job for a change under `Go/`
alone. The merge wave runs the same as `test-go`.

The rules (#1134): no cloud login is ever required, plain files only (no SQLite or other
embedded database), and today's file layout, so a change of language keeps every agent,
host and member.

## The control plane (`agents-control`, #1137)

The Go `agents-control` took the Swift one's command line (`serve`, `serve --home`,
`code`, `hosts`, `clients`, `install-script`, `store check`, `version`) and reads and
writes today's `control/` folder: the store, `control-key` (or the key on `--key-fd`),
and `tls/`, so its certificate's pin is the one every member holds. Every one of the
61 control-plane methods is answered; the handover's copy side is there too, so Agents
Host's *Move to another machine* and *Relay for my devices* work with it.

**Its wire is `Go/wire`'s** (#1313): every method's params and result, what it says to
clients and hosts, the exchange's lines and a channel's open frame are the generated types,
from `control.openrpc.json` and `daemon.schema.json`. A date is worked out as before
(`dateOf`), so no byte moved: `testdata/wire.golden` and each package's
`testdata/wire-types.golden` were written by the hand-made types and still pass. What stays
written by hand is not the wire: the store's records (ISO dates, and the fields a later
build added kept whole), the copies' own messages, and the JSON-RPC envelope.

| Package | What it ports |
|---|---|
| `controlplane/` | `ControlService`, `ControlRouter`, `ControlMethods`, `ControlCodes`, `CopyMesh`, `Leases`, `Handover`, `HostCopies`, `StoreSweep`, `ControlLog` |
| `controlplane/store`, `s3store` | The folder store (the default) and the bucket (an option) |
| `controlplane/records` | `ControlRecords`, in today's JSON |
| `controlplane/kms` | The key sealed by a keeper (an option, `AGENTS_CONTROL_KMS`) |
| `controlplane/web` | The web page's loopback listener |
| `controlplane/hostinstall`, `hosttunnels` | Add a Machine over ssh, Detect, the ssh config's hosts, bastion tunnels |
| `controlplane/notices` | Where a need shows (`Routing`), and the relay host's deliveries |
| `controlplane/providers` | Machine providers, kept requests, Write It for Me |

**Linux hosts run the Go agentsd** (#1136). `install.sh` installs it, from
`agentsd-linux-<arch>` (`scripts/build-linux-agentsd.sh`).

**On a Mac (#1312, #1314).** Agents Host carries `Contents/Helpers/agents-control`
(`scripts/go-control.sh`) and `Contents/Helpers/agentsd` (`scripts/go-agentsd.sh`), both Go:
its build fails with no Docker running and no Go. The host's launch agent runs `Agents Host
--launch-daemon`, which becomes `agentsd`; the control plane's runs `--launch-control`, which
hands over the key and becomes `agents-control`. The Swift ones, and the
`daemonImplementation` and `controlImplementation` settings that picked them, went in #1314.

**On a scratch set-up.** `.agents/skills/run-app/scripts/launch.sh` runs the ones the build
carries. `CONTROL_BIN=$PWD/Go/out/darwin/agents-control launch.sh --slug …` runs one built from
the tree (build it with `GOOS=darwin Go/scripts/go.sh build -o out/darwin/agents-control
./cmd/agents-control`).

## The github MCP server (`github-mcp`, #1232)

One stdio MCP server with GitHub's own tools and our events. The tools are the official
server's (`github.com/github/github-mcp-server/v2`, a library): by default the
`context,repos,issues,pull_requests,actions,labels` toolsets (`--toolsets` or
`GITHUB_TOOLSETS` names others), with merging and reviewing a pull request
(`HiddenTools`) never offered to the model. The events are the ones the ci server raised
(CIWatcher.swift, #383, removed in #1231), with the same names, arguments, data and eventIds, and the same cursor, paging and
trust filter (#728), polled only: `checks.failed`, `pr.opened`, `pr.merged`, `pr.closed`,
`pr.conflicted`, `issue.opened`, `issue.labelled`, `issue.commented`, `issue.closed`.
CodeRabbit's events are new here (#1344): `review.posted` (once per review of the head
commit: each time its `CodeRabbit` status on it goes to success, or its review with no status) and `review.comment` (each
review comment by it). Its tools `coderabbit_review`, `coderabbit_reply` and
`coderabbit_resolve` post its `@coderabbitai` commands as the person. There is no CodeRabbit
API or MCP server in this: it is known by its GitHub App (`coderabbitai`), not by a name.

MCP's SDKs have no events (a working-group draft), so `githubmcp.Front` reads stdio itself.
It answers `events/list` and `events/poll`, adds the `events` capability to `initialize`,
and passes every other message to the official server unchanged. It calls GitHub as the
person, with the token of the host's GitHub connection (#1335: the GitHub App
`agents-loops`, device flow), read again each minute from the store `AGENTS_CONNECTIONS`
names. It has no account of its own and does not use `gh`.

Agents Host carries it in `Contents/Helpers` (`scripts/go-github-mcp.sh`, a build phase,
as `agents-control` is), and `scripts/build-linux-agentsd.sh` builds
`github-mcp-linux-<arch>`, which every Linux host installs beside agentsd. A folder names
it by bare name: `"github": { "command": "github-mcp", "hosted": true }`.

## The linear MCP server (`linear-mcp`, #839)

The event half of `github-mcp`'s shape: a stdio front (`linearmcp.Front`) answers
`events/list` and `events/poll` and passes everything else to a go-sdk server with no tools.
The tools are Linear's own MCP server's (`https://mcp.linear.app/mcp`, OAuth), added from the
marketplace; this server runs beside agentsd with a personal API key in `LINEAR_API_KEY`.

- **Events**, polled every minute (a personal key has 1500 requests an hour):
  `issue.opened`, `issue.labelled`, `issue.commented`, `issue.closed` (into a Done or
  Canceled state), with the github server's cursor and paging. Arguments `team` (a key, as
  `ENG`), `label`, `issue` (as `ENG-12`) and `anyone`; left out, only the workspace's members
  count, never a guest or an app (#728).

It reads Linear's GraphQL API (`LINEAR_MCP_API_URL` moves it, for a fake). Agents Host carries
it (`scripts/go-github-mcp.sh linear-mcp`) and every Linux host installs
`linear-mcp-linux-<arch>`. See `docs/how-to/use-linear-issues.md`.

## The gitlab MCP server (`gitlab-mcp`, #1629)

The github server's shape for GitLab: a stdio front (`gitlabmcp.Front`) answers
`events/list` and `events/poll` and passes everything else to a go-sdk server with our own
tools, all over GitLab's REST API v4 with one token: the person's GitLab connection (#1630,
Connectors ▸ Connect GitLab: the device flow on gitlab.com, or an access token on any
GitLab), or `GITLAB_TOKEN` (an access token with the `api` scope), which goes first.
`GITLAB_URL` (or `--url`) is the GitLab: the connection's when empty, else
`https://gitlab.com`. The connection's token goes only to the GitLab it was made on. GitLab's own MCP server
(`/api/v4/mcp`) is not behind it: it takes no classic access token and needs "Allow access
to the MCP server" turned on for the top-level group or the instance.

- **Events**, polled every 30 s, with the github server's names, cursor and paging; a merge
  request is a `pr` (its iid is `number`): `checks.failed` (a merge request's failed
  pipeline), `pr.opened`, `pr.merged`, `pr.closed`, `pr.conflicted`, `review.comment` (a
  comment on a line of the diff), `issue.opened`, `issue.labelled` (one per label added, from
  the issues updated since and their label events), `issue.commented`, `issue.closed`.
  Arguments `project` (a path, as `group/sub/app`, or an id; left out, the project this
  folder pushes to), `branch`, `pr`, `label`, `issue` and `anyone`; left out, only the
  project's members with Reporter access or more count, never a bot or a fork (#728).
- **Tools:** `list_merge_requests`, `get_merge_request`, `list_pipelines`, `get_pipeline`,
  `list_issues`, `get_issue` (with its comments, each marked `trusted` or not),
  `comment_on_merge_request`, `comment_on_issue`; for the ready-made workflows (#1633)
  `create_merge_request`, `list_merge_request_comments` and `reply_to_merge_request_comment`;
  and `merge_merge_request`, which only a view may call (a person merges, as on GitHub).
- **Views** (#1631), the github server's page shapes in GitLab's words (`pages/`; `bridge.js`,
  `common.css` and `mrpage.css` are the github server's, word for word, and a test keeps them
  so): Merge requests (`show_merge_requests`), Issues (`show_issues`) and a merge request's
  page (`show_merge_request`), with `show_merge_request_diff` for the app's diff,
  `failed_log`, `retry_pipeline`, and `approve_merge_request` for a view only.
  `walk/walk.mjs` draws them in headless Chrome against a stand-in GitLab.

The tests run it against a fake GitLab over HTTP (`fake_test.go`). Agents Host carries it
(`scripts/go-github-mcp.sh gitlab-mcp`) and every Linux host installs
`gitlab-mcp-linux-<arch>` (#1636); the catalogue lists it as `agents/gitlab`, which asks for
no secret: it reads the connection, as the linear server does.

## The email MCP server (`email-mcp`, #1780)

The gitlab server's shape for one IMAP mailbox (`github.com/emersion/go-imap/v2`): a stdio
front (`emailmcp.Front`) answers `events/list` and `events/poll` and passes everything else to
a go-sdk server with its tools. The account is the person's email connection (Connect Email:
the IMAP server, the user and an app password), or `EMAIL_IMAP_URL`, `EMAIL_USER` and
`EMAIL_PASSWORD`, which go first. It is read at each sign-in. `imaps://` (993) by default,
`imap://` with STARTTLS, and `imap+insecure://` on this machine only, for a fake.

- **Event** `email.received`, polled: arguments `from`, `to`, `subject` (globs, such as
  `*@gitlab.com`) and `folder` (INBOX when left out). Its data is the message's id, folder,
  from, to, subject and date, never its text. IDLE holds each folder asked about (four at
  most), so a quiet poll asks the server nothing and the pace is 10 s; with no IDLE, 60 s.
- **Tools:** `list_folders`, `list_messages`, `search_messages`, `read_message` (its text
  inside `<untrusted-content source="email">`, as outside content), `mark_read` and
  `move_message`. Reading leaves a message unread. Nothing sends, answers or deletes mail.

The tests run it against go-imap's in-memory IMAP server (`fake_test.go`). Agents Host
carries it (`scripts/go-github-mcp.sh email-mcp`) and every Linux host installs
`email-mcp-linux-<arch>`; the catalogue lists it as `agents/email`, which asks for no secret:
it reads the connection.

## The command machine provider (`workspace-commands`, #691, #1364)

A machine provider whose workspaces are shell commands: written out, listed by one command,
or a preset (`docker`, `doctl`, `codespaces`, `coder`, `gcloud-workstations`). Its configuration
is the JSON in `WORKSPACE_COMMANDS_CONFIG`, as
`specs/691-workspace-providers/contracts/command-provider.md` says; it was Swift
(`Packages/MCPServers`) until #1364, and a configuration written for that one works unchanged.
It answers MCP on stdio by itself, with no SDK: initialize, ping and the contract's tools.

The control plane runs it from beside itself, then `AGENTS_WORKSPACE_COMMANDS`, then `PATH`
(`internal/controlplane/providers`). Agents Host carries it beside `agents-control`
(`scripts/go-github-mcp.sh workspace-commands`); the control-plane image has it beside
`agents-control` (`deploy/Containerfile` builds both).
