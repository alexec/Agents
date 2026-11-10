# Go

The daemon (`agentsd`) and the control plane (`agents-control`), moved from Swift to Go
(#1134; the Swift ones went in #1314). One module, so the two share the wire types and the
control exchange. The Mac window, the Remote, `Shared/UI`, the web page and Agents Host
stay as they are.

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
| `cmd/jira-mcp/`, `internal/jiramcp/` | The `jira` MCP server (#3247): Jira's issue events and Issues page, in linear-mcp's shape (tools are Atlassian's own server's) | ci-server |
| `cmd/email-mcp/`, `internal/emailmcp/` | The `email` MCP server (#1780): one IMAP mailbox's new mail as `email.received`, and tools that read it; it never sends | email |
| `cmd/slack-mcp/`, `internal/slackmcp/` | The `slack` MCP server (#1351): a Slack app's bot over Socket Mode, `message.received` and `question.answered`, and tools that read, send and ask | channels |
| `cmd/googlechat-mcp/`, `internal/googlechatmcp/` | The `googlechat` MCP server (#1016): a Google Chat app's messages and answers as `message.received` and `question.answered`, pulled from Pub/Sub, and tools that post as the app | googlechat |
| `cmd/sentry-mcp/`, `internal/sentrymcp/` | The `sentry` events MCP server (#3583): an organization's new and regressed issues as `health.issue_new` and `health.issue_regressed`, polled on Sentry's REST API; no tools (Sentry's own server has them) | sentry |
| `cmd/betterstack-mcp/`, `internal/betterstackmcp/` | The `betterstack` events MCP server (#3655): a team's incidents as `health.incident_started` and `health.incident_resolved`, polled on Better Stack's Uptime API; no tools (Better Stack's own server has them) | betterstack |
| `cmd/whatsapp-mcp/`, `internal/whatsappmcp/` | The `whatsapp` MCP server (#1352): a WhatsApp Business number's messages and answers as `message.received` and `question.answered`, by Meta's signed webhook, and tools that send as the number | whatsapp |
| `cmd/gitlab-mcp/`, `internal/gitlabmcp/` | The `gitlab` MCP server (#1629): merge requests, pipelines and issues on GitLab, tools and events on REST v4 | gitlab |
| `cmd/forgejo-mcp/`, `internal/forgejomcp/` | The `forgejo` MCP server (#1753): pull requests, checks and issues on Forgejo or Gitea, tools, events and views on REST v1, in the gitlab server's shape | forgejo |
| `cmd/bitbucket-mcp/`, `internal/bitbucketmcp/` | The `bitbucket` MCP server (#2828): pull requests, checks and issues on Bitbucket Cloud, tools, events and views on REST 2.0, in the gitlab server's shape | bitbucket |
| `cmd/azuredevops-mcp/`, `internal/azuredevopsmcp/` | The `azuredevops` MCP server (#2829): pull requests and Azure Pipelines builds on Azure DevOps, tools, events and views on REST 7.1, in the gitlab server's shape | azuredevops |
| `cmd/azureboards-mcp/`, `internal/azureboardsmcp/` | The `azureboards` MCP server (#3804): Azure Boards work items as a tracker, tools and events on REST 7.1, in the jira server's shape | azureboards |
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
Host's *Move to another machine* works with it.

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
| `controlplane/notices` | Where a need shows (`Routing`), and which device gets its notice (`Desk`) |
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
`run.completed` is new here (#3444): a workflow run that finished, whatever started it and
whatever its conclusion, for the runs no pull request owns (a tag's `release.yml`, a
`workflow_dispatch` dry run); `workflow`, `branch` (a branch or a tag) and `run` filter it.
Its `deploys` are what the run's jobs say they deployed (#3584), each a notice
`::notice title=deploy::<target>:<id>/<version>`, as `testflight:<bundle id>/<build>` or
`appstore:<bundle id>/<version>` (#3657): one
request for the run's check suite, and one for each job that has annotations.
`deploy.waiting` (#3587) is a run held by an environment with required reviewers (a job's
`environment: production`), once per run, attempt and set of environments, with the
reviewers and `canApprove` (whether the connected account is one of them); `workflow` and
`branch` filter it. Agents Host reads the same waits for Needs You (`agentsd/deploys.go`).
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

## The jira MCP server (`jira-mcp`, #3247)

The linear server's shape for Jira Cloud and Jira Data Center: a stdio front
(`jiramcp.Front`) answers `events/list` and `events/poll`, and passes everything else to a
go-sdk server with `show_issues` and `show_issue_details` and the `ui://jira/issues` page.
The tools that change issues are Atlassian's own MCP server's (`https://mcp.atlassian.com/v1/mcp`,
OAuth), added from the marketplace.

- **Signs in** with the person's Atlassian connection (`connections.Atlassian`, #3304): a 3LO
  token goes to `api.atlassian.com/ex/jira/<cloud id>`, a site token to the site. A token set
  by hand (below) goes first.
- **Reads** Jira's REST API version 2 at `JIRA_URL`: with `JIRA_EMAIL` and `JIRA_API_TOKEN`,
  Jira Cloud (Basic, search by `/search/jql`); with `JIRA_API_TOKEN` alone, a Data Center
  personal access token (Bearer, search by `/search`). A description is Jira's rendered HTML,
  made safe by `richtext.HTML`.
- **Events**, polled every minute (Jira's webhooks need a Jira admin): `issue.opened`,
  `issue.labelled` and `issue.assigned` (from the changelog), `issue.commented`, with the
  linear server's cursor and paging. JQL's times are to the minute in the user's zone, so it
  asks by minutes ago and checks the time itself. Arguments `project` (a key, as `PROJ`),
  `label`, `issue` (as `PROJ-12`) and `anyone`; left out, only the site's own users count,
  never a customer or an app (#728).

Agents Host carries it (`scripts/go-github-mcp.sh jira-mcp`) and every Linux host installs
`jira-mcp-linux-<arch>`. See `docs/how-to/use-jira-issues.md`.

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

## The forgejo MCP server (`forgejo-mcp`, #1753)

The gitlab server's shape for Forgejo and Gitea, which share one REST API (v1): a stdio front
(`forgejomcp.Front`) answers `events/list` and `events/poll` and passes everything else to a
go-sdk server with our own tools, all with one token: the person's Forgejo connection (#3752,
an access token the host checked and keeps, in the store `connections.EnvName` names), or
`FORGEJO_TOKEN` (an access token with read and write on repository and issue, and read on
user and organization), which comes first. `FORGEJO_URL` (or `--url`) is the Forgejo or
Gitea: the connection's, else `https://codeberg.org`. The connection's token goes only to the
Forgejo it was made on.

- **Events**, polled every 30 s, with the gitlab server's names, cursor and paging:
  `checks.failed` (an open pull request's head commit whose combined commit status is
  failure or error: Forgejo Actions, Woodpecker or any CI; the 50 open pull requests updated
  last are read), `pr.opened`, `pr.merged`, `pr.closed`, `pr.conflicted` (not mergeable for a
  minute at one head: Forgejo says not mergeable while it checks too), `review.requested`,
  `review.comment` (the reviews of the pull requests updated since), `issue.opened`,
  `issue.labelled` and `issue.closed` (the timelines of the issues updated since),
  `issue.commented` (the repository's issue comments), `issue.assigned`. Arguments `repo`
  (`owner/name`; left out, the repository this folder pushes to), `branch`, `pr`, `label`,
  `issue`, `anyone` and `mine`; left out, only the owner, collaborators with write access or
  more and the owning organisation's members count, never a bot or a fork (#728). A token
  without admin cannot read another person's access, so it falls back to whether they are a
  collaborator or a member.
- **Tools:** `list_pull_requests`, `get_pull_request`, `get_checks`, `list_issues`,
  `get_issue`, `comment_on_pull_request`, `comment_on_issue`; `failed_log` (the end of a
  failed Forgejo Actions run's jobs' logs, Forgejo 16 or Gitea 1.25, #3761) and
  `retry_pipeline` (its failed jobs again, Forgejo 17 or Gitea 1.26, #3842), each by the
  run's number (`run.id` in `checks.failed`); for the ready-made workflows
  (#1633) `create_pull_request`, `list_pull_request_comments` and
  `reply_to_pull_request_comment` (a review comment on the same file and line, which Forgejo
  keeps in that thread); and, on the host's copy only, `merge_pull_request` and
  `approve_pull_request` (a person merges, as on GitHub).
- **Set-up reads** (`setup.go`, #3752): the newest issue, the newest pull request and the
  default branch's combined status prove a folder's Tasks, Code review and CI slots, and
  `RepoAt` finds a folder's Forgejo repository from its remotes.
- **Views** (#3838), the gitlab server's page shapes in Forgejo's words (`pages/`; `bridge.js`,
  `common.css`, `lineage.js` and `prpage.css` are the github server's, word for word, and a test
  keeps them so): Pull requests (`show_pull_requests`), Issues (`show_issues`, with
  `show_issue_details`) and a pull request's page (`show_pull_request`), with
  `show_pull_request_diff` for the app's diff, `failed_log` for a failed run's log and
  `retry_pipeline` for Retry.

The tests run it against a fake Forgejo over HTTP (`fake_test.go`); `walk_live_test.go`
(`-tags live`) walks every event and tool on a real Forgejo or Gitea, a scratch one in a
container. Agents Host carries it (`scripts/go-github-mcp.sh forgejo-mcp`) and every Linux
host installs `forgejo-mcp-linux-<arch>`; the catalogue lists it as `agents/forgejo`, which
asks for no secret: it reads the connection, as the gitlab server does. See `docs/how-to/use-forgejo.md`.

## The bitbucket MCP server (`bitbucket-mcp`, #2828)

The forgejo server's shape for Bitbucket Cloud's REST API 2.0: a stdio front
(`bitbucketmcp.Front`) answers `events/list` and `events/poll` and passes everything else to a
go-sdk server with our own tools, all with one token: the person's Bitbucket connection
(#3785, a token the host checked and keeps, in the store `connections.EnvName` names), or
`BITBUCKET_TOKEN`, which comes first. Either is an Atlassian API token with scopes (with its
email, `BITBUCKET_EMAIL`, as Basic auth) or a repository, project or workspace access token
(as a Bearer token). Bitbucket Cloud only; `BITBUCKET_API_URL` (or `--api`) points it, and the
host's token check, at a fake. The connection's token goes only to the API it was made on.

- **Events**, polled every 30 s, with the gitlab server's names, cursor and paging:
  `checks.failed` (a FAILED commit status on an open pull request's head: Pipelines or any
  CI), `pr.opened`, `pr.merged` and `pr.closed` (declined; the time is the activity's state
  change, as `updated_on` moves with every comment), `pr.conflicted` (a file of the
  diffstat in conflict), `review.requested`, `review.comment` (inline comments of the pull
  requests updated since), `issue.opened`, `issue.labelled` and `issue.closed` (the changes
  of the issues updated since; an issue's kind and component are its labels),
  `issue.commented`, `issue.assigned`. The trust filter (#728): write or admin by the
  repository's permissions, falling back to the workspace's members for a token without
  admin, never an app or a bot, never a fork.
- **Tools:** the forgejo server's, by the same names; `merge_pull_request` and
  `approve_pull_request` on the host's copy only, refused when the head is not the commit
  the person saw.
- **Set-up reads** (`setup.go`, #3785): the newest issue, the newest pull request and the
  main branch's statuses prove a folder's Tasks, Code review and CI slots (a tracker that is
  off says so), and `RepoAt` finds a folder's Bitbucket repository from its remotes.
- **Views** (`views.go`, `pages.go`, `pages/`, #3866): the forgejo server's pages in
  Bitbucket's words: Pull requests (`ui://bitbucket/pull-requests`), Issues
  (`ui://bitbucket/issues`) and a pull request's page (`ui://bitbucket/pr`), fed by
  `show_pull_requests`, `show_issues` and `show_pull_request`, with `show_issue_details` and
  `show_pull_request_diff` (`PRDiff`, the Work pages' read). Lists in sections for the viewer;
  a thread is a comment on a line and its answers, by `parent`; Show Log and Run Again on a
  failed Pipelines run; no Auto-merge (Bitbucket's API has none). `bridge.js`, `common.css`,
  `lineage.js` and `prpage.css` are the github server's, word for word; a test keeps them so.

The tests run it against a fake Bitbucket over HTTP (`fake_test.go`). Agents Host carries it
(`scripts/go-github-mcp.sh bitbucket-mcp`) and every Linux host installs
`bitbucket-mcp-linux-<arch>`; the catalogue lists it as `agents/bitbucket`, which asks for no
secret: it reads the connection, as the forgejo server does. See
`docs/how-to/use-bitbucket.md`.

## The azuredevops MCP server (`azuredevops-mcp`, #2829)

The gitlab server's shape for Azure DevOps Services and Azure DevOps Server (REST API 7.1): a
stdio front (`azuredevopsmcp.Front`) answers `events/list` and `events/poll` and passes
everything else to a go-sdk server with our own tools, all with one personal access token,
`AZURE_DEVOPS_TOKEN` (Code read and write, Build read), sent as Basic. `AZURE_DEVOPS_URL` (or
`--url`) is a server's collections, such as `https://server/tfs`: `https://dev.azure.com`
when empty. A repository is `organization/project/name`.

- **Events**, polled every 30 s, with the gitlab server's names, cursor and paging, for pull
  requests only: `checks.failed` (a pull request build that failed at an active pull
  request's head commit, from the builds finished since), `pr.opened`, `pr.merged`
  (completed), `pr.closed` (abandoned; both from the pull requests closed since,
  `queryTimeRangeType=closed`), `pr.conflicted` (`mergeStatus` is `conflicts`),
  `review.requested` (the token's owner is a reviewer with no vote), `review.comment` (the
  threads of the 50 newest active pull requests and of those closed since). Arguments
  `repo`, `branch`, `pr`, `anyone` and `mine`; left out, never a bot (a build service, a
  group) or a fork (#728). Only a project's members can write to it, so no access is read.
- **Tools:** `list_pull_requests`, `get_pull_request`, `get_checks`, `get_build_log` (a
  build's failed steps from its timeline, and the end of each log),
  `comment_on_pull_request`; for the ready-made workflows (#1633) `create_pull_request`,
  `list_pull_request_comments` and `reply_to_pull_request_comment` (by `threadId`);
  `retry_build` (a build's failed jobs again, #4098); and, on the host's copy only,
  `merge_pull_request` and `approve_pull_request`.
- **Views** (`views.go`, `pages.go`, `pages/`, #4098): the forgejo server's pages in Azure
  DevOps's words: Pull requests (`ui://azuredevops/pull-requests`) and a pull request's page
  (`ui://azuredevops/pr`), fed by `show_pull_requests` and `show_pull_request`, with
  `show_pull_request_diff` (`PRDiff`, the Work pages' read). The list is in sections for the
  viewer, Team by the control plane's people's Azure DevOps logins (#3853) as the
  azureboards server has them; Show Log and Retry Failed Jobs on a failed build; Auto-merge is
  auto-complete. `bridge.js`, `common.css`, `lineage.js` and `prpage.css` are the github
  server's, word for word; a test keeps them so.
- **No work items:** they are the tracker's (the azureboards server, with its own Issues page).

Not Microsoft's own server (`@azure-devops/mcp`, MIT): it needs Node on every host, it offers
agents the votes and the completion that only a person may give (#837), and it has no events,
which need their own REST client anyway. The tests run against a fake Azure DevOps over HTTP
(`fake_test.go`). Agents Host carries it (`scripts/go-github-mcp.sh azuredevops-mcp`) and
every Linux host installs `azuredevops-mcp-linux-<arch>`; the catalogue lists it as
`agents/azuredevops`. See `docs/how-to/use-azure-devops.md`.

## The azureboards MCP server (`azureboards-mcp`, #3804)

The jira server's shape for Azure Boards, the tracker of Azure DevOps (REST API 7.1): a stdio
front (`azureboardsmcp.Front`) answers `events/list` and `events/poll` and passes everything
else to a go-sdk server with its tools. It is its own server, not part of `azuredevops-mcp`,
because the catalogue runs one connector a command and a tracker is chosen apart from the
code host. It shares the azuredevops server's token, `AZURE_DEVOPS_TOKEN` (with Work Items
read and write), and `AZURE_DEVOPS_URL`; `AZURE_BOARDS_PROJECT` (or `--project`) is
`organization/project`, the folder's Azure Repos remote's when empty.

- **Events**, polled every minute, with the jira and linear servers' names and cursor:
  `issue.opened` (WIQL on `System.CreatedDate`), and from the 50 work items changed since
  (WIQL on `System.ChangedDate`, `timePrecision=true`, then `workitemsbatch`):
  `issue.labelled` (a tag added in an update), `issue.closed` (an update into a state of the
  Completed or Removed category, from the work item types' states), `issue.assigned` (an
  update that assigns the token's owner) and `issue.commented` (the comments API,
  7.1-preview.4). An update's time is its `System.ChangedDate`, not its `revisedDate`.
  Arguments `area`, `type`, `label`, `issue` and `anyone`; left out, never a bot (#728).
- **Tools:** `list_work_items`, `get_work_item` and `comment_on_work_item` (Markdown).
- **No views yet,** and no Work pages, Tasks slot or board.

It imports only `azuredevopsmcp.BaseURL` and `GitRepo` from the azuredevops server; its HTTP
client is its own, as each of our servers' is. The tests run against a fake Azure DevOps over
HTTP (`fake_test.go`). Agents Host carries it (`scripts/go-github-mcp.sh azureboards-mcp`)
and every Linux host installs `azureboards-mcp-linux-<arch>`; the catalogue lists it as
`agents/azureboards`. See `docs/how-to/use-azure-boards.md`.

## The email MCP server (`email-mcp`, #1780)

The gitlab server's shape for one IMAP mailbox (`github.com/emersion/go-imap/v2`): a stdio
front (`emailmcp.Front`) answers `events/list` and `events/poll` and passes everything else to
a go-sdk server with its tools. The account is the person's email connection (Connect Email:
the IMAP server, the user and an app password), or `EMAIL_IMAP_URL`, `EMAIL_USER` and
`EMAIL_PASSWORD`, which go first. It is read at each sign-in. `imaps://` (993) by default,
`imap://` with STARTTLS, and `imap+insecure://` on this machine only, for a fake.

- **Event** `email.received`, polled: arguments `from`, `to`, `subject` (globs, such as
  `*@gitlab.com`) and `folder` (INBOX and the Junk folder when left out, #3912; the Junk folder
  is the one whose role is `\Junk`, or with no role, one named Junk or Spam). Its data is the message's id, folder,
  from, to, subject and date, never its text. IDLE holds each folder asked about (four at
  most), so a quiet poll asks the server nothing and the pace is 10 s; with no IDLE, 60 s.
- **Tools:** `list_folders`, `list_messages`, `search_messages`, `read_message` (its text
  inside `<untrusted-content source="email">`, as outside content), `mark_read` and
  `move_message`; and the messaging contract's `list_conversations` and `read_messages`
  (#4340, `docs/reference/messaging-contract.md`, `_meta` `"agents/messaging": 1`). A
  conversation is a thread, made from `References`, `In-Reply-To`, and the subject of a
  reply that has neither (`threads.go`): `list_conversations` groups a window of the folder's
  newest mail (ten for each conversation asked for, 500 at most) and leaves out a thread that
  an earlier page listed; `read_messages` searches the folder and the Sent folder for the
  thread's root `Message-ID`, newest first, by cursor. Reading leaves a message unread.
  Nothing sends, answers or deletes mail.

The tests run it against go-imap's in-memory IMAP server (`fake_test.go`). Agents Host
carries it (`scripts/go-github-mcp.sh email-mcp`) and every Linux host installs
`email-mcp-linux-<arch>`; the catalogue lists it as `agents/email`, which asks for no secret:
it reads the connection.

## The Slack MCP server (`slack-mcp`, #1351)

The email server's shape for one Slack workspace (`github.com/slack-go/slack`): a stdio front
(`slackmcp.Front`) answers `events/list` and `events/poll` and passes everything else to a
go-sdk server with its tools. The bot token (`SLACK_BOT_TOKEN`, `xoxb-`) calls the Web API;
the app-level token (`SLACK_APP_TOKEN`, `xapp-`, `connections:write`) holds a Socket Mode
connection open (`slackmcp.Listener`), so Slack needs no public address. Each request is
acknowledged at once and put in an inbox in memory (the last 1,000); a poll reads it, so the
pace is 3 s and a poll costs Slack nothing. A cursor from an earlier run starts from now.

- **Events** `message.received` (`channel`, `user`, `thread`, `mentions`) and
  `question.answered` (`question`, `channel`). Neither has a message's text. Each has a
  `sender` (`slack`, `team/user`, and the name and email from `users.info`) for a channel
  link (#1762). Edits, deletions, joins and bots' messages are left out.
- **Tools:** `list_channels`; the messaging contract's `list_conversations` and
  `read_messages` (#4339, `docs/reference/messaging-contract.md`, `_meta`
  `"agents/messaging": 1`: newest first, by cursor, the text inside
  `<untrusted-content source="slack">`; `read_messages` still takes `channel` for
  `conversation`); `send_message` and `ask_question` (the options as
  buttons in an `actions` block, `agents-question:<id>`; the first press is the answer, and
  `chat.update` puts who answered in their place). No `@channel`, `@here` or `@everyone`.

The tests run it against a fake Web API and Socket Mode over a WebSocket (`fake_test.go`).
Agents Host carries it (`scripts/go-github-mcp.sh slack-mcp`) and every Linux host installs
`slack-mcp-linux-<arch>` (#3475); the catalogue lists it as `agents/slack`, which asks for
the two tokens as secrets. See `docs/how-to/reach-agents-from-slack.md`.

## The Google Chat MCP server (`googlechat-mcp`, #1016)

The email server's shape for one Google Chat app, with Google's own REST clients
(`google.golang.org/api/chat/v1` and `pubsub/v1`): a stdio front (`googlechatmcp.Front`)
answers `events/list` and `events/poll` and passes everything else to a go-sdk server with its
tools. The app's service account key (`GOOGLE_CHAT_CREDENTIALS`: its JSON, or its file's path)
signs in to both APIs; `GOOGLE_CHAT_SUBSCRIPTION` names the Pub/Sub subscription
(`agents-chat` in the key's project when left out). Both are read at each call.

- **Events** `message.received` (filters `space`, `text`, a glob, and `direct`) and
  `question.answered` (filters `space` and `question`), polled. One loop, started by the first
  poll, pulls the subscription into an inbox in memory and acknowledges what it pulled; each
  poll's cursor is a place in that inbox (the run and a number), so every workflow reads the
  same list. The inbox keeps the newest 1,000 for a day; the pace is 3 s. Each event's
  `sender` is the Google Chat user (`users/…`), with the name and email, for a channel link
  (#1762). Only a person's events are raised: a bot's, and the app being added or removed,
  are not.
- **Tools:** `list_spaces`, `send_message` and `ask_question`, a card with a button per
  option whose press calls `agents.answer` with the question's id; the first press is
  `question.answered`, and the server then edits the card to say who answered.

The tests run it against a fake Pub/Sub and Chat API over HTTP (`fake_test.go`;
`GOOGLE_CHAT_API_URL` and `GOOGLE_CHAT_PUBSUB_URL` point a real run at one). Agents Host
carries it (`scripts/go-github-mcp.sh googlechat-mcp`) and every Linux host installs
`googlechat-mcp-linux-<arch>`; the catalogue lists it as `agents/googlechat`, which asks for
the key. See `docs/how-to/use-google-chat.md`.

## The WhatsApp MCP server (`whatsapp-mcp`, #1352)

The Google Chat server's shape for one WhatsApp Business number on Meta's Cloud API, with Go's
own `net/http`: the Cloud API is one JSON call (`POST /<phone number id>/messages`) and a
signed webhook. `WHATSAPP_TOKEN` (a system user's token), `WHATSAPP_PHONE_NUMBER_ID`,
`WHATSAPP_APP_SECRET` and `WHATSAPP_VERIFY_TOKEN` are read at each call.

- **The webhook:** the Cloud API has no pull and no socket, so the server serves Meta's
  webhook itself, on `WHATSAPP_WEBHOOK_ADDR` (`127.0.0.1:8797` when left out), from its start
  when the account is set, else from the first poll. The person puts a public HTTPS address in
  front of it (a tunnel, or the machine's reverse proxy). `GET` answers Meta's check with the
  verify token; a `POST` is taken only when its `X-Hub-Signature-256` is the app secret's
  HMAC, so nobody else can fake a sender. When the address is taken, a poll says so.
- **Events** `message.received` (filters `space`, the person's number, `text`, a glob, and
  `direct`, which is every message) and `question.answered` (filters `space` and `question`),
  polled, with the Google Chat server's inbox and cursor: the newest 1,000 for a day, a call
  Meta sends again kept once. Each event's `sender` is the number (`wa_id`) and the profile's
  name, for a channel link (#1762); WhatsApp gives no email address. A text, a template's
  quick reply, and a photo, video or document's caption are raised; a sticker, a voice note
  and a status are not. Each message kept is marked read.
- **Tools:** `send_message`, `ask_question` (reply buttons for up to three options, a list
  for up to ten; each option's id is `agents|<question>|<option>`, and the first press is
  `question.answered`), `send_template` (an approved template: the only message Meta takes
  more than 24 hours after the person last wrote), and the messaging contract's
  `list_conversations` and `read_messages` (#4341, `docs/reference/messaging-contract.md`,
  `_meta` `"agents/messaging": 1`: a conversation is a person's number, newest first, by
  cursor, marked as outside content; `read_messages` still takes `from` for
  `conversation`). A refusal for the 24-hour window says to use `send_template`.
- **The store:** the Cloud API reads no history, so each message the webhook keeps and each
  message the number sends goes to `~/.agents/whatsapp/<phone number id>.json`
  (`WHATSAPP_STORE_DIR`): the newest 2,000 for 30 days, at most 4 MB of text, written to a
  temporary file and moved into place under a lock, so every copy of the server adds to it and
  reads all of it. A file that cannot be read is kept aside as `.unreadable.json`.

The tests run it against a fake Cloud API over HTTP and signed webhook calls (`fake_test.go`;
`WHATSAPP_API_URL` points a real run at one). Agents Host carries it
(`scripts/go-github-mcp.sh whatsapp-mcp`) and every Linux host installs
`whatsapp-mcp-linux-<arch>`; the catalogue lists it as `agents/whatsapp`, which asks for the
four values as secrets. See `docs/how-to/use-whatsapp.md`.

## The Sentry events MCP server (`sentry-mcp`, #3583)

Sentry's official MCP server (`getsentry/sentry-mcp`) is TypeScript and has tools but no
events, so the catalogue offers it as a remote (`https://mcp.sentry.dev/mcp`, signed in by
the app's MCP OAuth) and `sentry-mcp` adds the events, as `github-mcp` adds them to GitHub's.
It is the slack server's front with no tools, on Go's own `net/http` (the sentry-go SDK sends
errors and has no API client). `SENTRY_AUTH_TOKEN`, `SENTRY_ORG` and `SENTRY_URL` are read at
its start.

- **Events** `health.issue_new` (an issue whose first event is after the cursor) and
  `health.issue_regressed` (an issue's last `set_regression` activity after it, once per
  regression), filters `project`, `environment` and `level`, polled every 30 seconds. The
  cursor is a time and the issues raised from 30 minutes before it, as the github server's,
  so the server keeps nothing; each poll looks back 30 minutes for an issue whose first
  event came in late. The data is the organization, the project, the issue and the release
  that saw it (the issue's `firstRelease`, or the regression's own release).

The tests run it against a fake Sentry API (`sentry_test.go`), and agentsd's
`sentryevents_test.go` wakes a wait through it. Agents Host carries it
(`scripts/go-github-mcp.sh sentry-mcp`) and every Linux host installs
`sentry-mcp-linux-<arch>`; the catalogue lists it as `agents/sentry`. See
`docs/how-to/use-sentry.md`.

## The Better Stack events MCP server (`betterstack-mcp`, #3655)

Better Stack's official MCP server (`https://mcp.betterstack.com`) has tools, status pages
included, but no events, so the catalogue offers it as a remote (`com.betterstack/mcp`,
signed in by the app's MCP OAuth) and `betterstack-mcp` adds the events, as `sentry-mcp`
does for Sentry. It is the sentry server's front with no tools, on Go's own `net/http`
(Better Stack has no Go SDK). `BETTERSTACK_API_TOKEN`, `BETTERSTACK_TEAM` and
`BETTERSTACK_URL` are read at its start.

- **Events** `health.incident_started` (an incident that started after the cursor) and
  `health.incident_resolved` (one resolved after it, that started at most 7 days before),
  filter `monitor`, polled every 30 seconds. Incidents are read by the day they started, at
  most 4 pages of 50; a next page on another host is not followed. The cursor is a time and
  the incidents raised from 30 minutes before it, as the sentry server's. The data is the
  team, the incident (id, the monitor's name, cause, address, monitor id) and its times.

The tests run it against a fake Better Stack API (`betterstack_test.go`), and agentsd's
`betterstackevents_test.go` wakes a wait through it. Agents Host carries it
(`scripts/go-github-mcp.sh betterstack-mcp`) and every Linux host installs
`betterstack-mcp-linux-<arch>`; the catalogue lists it as `agents/betterstack`. See
`docs/how-to/use-better-stack.md`.

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
