---
diataxis: reference
devices: [mac, iphone, ipad, web, server]
description: Every third-party service and tool the app talks to, starts, installs or signs in to, with its state and when it was last checked.
---

# Integrations

This page gives the status of every third-party integration, one table for each type. An
integration is something the product talks to, starts, installs or signs in to: something a
person sets up, or something that an outside change can break. Build and release tools
(TestFlight, App Store Connect, the sign-up scripts) and bundled libraries (SwiftTerm,
Mermaid) are not on this page.

**Columns:**

- **Clients that show it:** Mac (the window), Remote (iPhone and iPad), web, server (a Linux
  host), control plane, or agents (only agents use it).
- **State:** `planned`, `built`, `walked on scratch`, `tested on a real account`, `broken` or
  `removed`.
- **Last checked:** the date of the last assessment or walk, and where its record is. A dash
  means that no check is recorded.
- **Where:** the file that defines it.
- **Gaps:** open issues. Each section names an issue search for its open issues with the `integration` label.

**Keeping it current:** a pull request that changes the state of an integration (added,
removed, walked, tested on a real account, broken, fixed) updates its row in the same branch.
The runtime check, run once per release, writes the rows between the `runtimes` markers below; edit all other
rows by hand. A new type of integration adds a section.

All open integration issues: the issue search `is:open label:integration`.

## Runtimes

The coding agents the app starts. What each can do is in [Runtimes](runtimes.md). Defined in
`Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/RuntimeCatalog.swift` (Mac) and
`Go/internal/agentsd/runtimes.go` (Go hosts).
Open issues: `is:open label:integration runtime`.

<!-- runtimes:begin -->
| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| Claude | Mac, Remote, web, server | broken (fails at handshake) | 2026-10-17, 0.93.0: failed at handshake, in `.agents/reviews/runtimes/claude-2026-10-17.md` | `RuntimeCatalog.swift`, `runtimes.go` | |
| Grok | Mac, Remote, web, server | tested on a real account | 2026-10-27, 1.0.67: a real turn passed, not assessed, in `.agents/reviews/runtimes/grok-2026-10-27.md` | `RuntimeCatalog.swift`, `runtimes.go` | Sandbox control unavailable until Grok supports it over ACP |
| Copilot | Mac, Remote, web, server | broken (fails at turn) | 2026-10-17, 1.0.93-1: failed at turn, in `.agents/reviews/runtimes/copilot-2026-10-17.md` (skipped 2026-10-27: Copilot its allowance is spent on this Mac) | `RuntimeCatalog.swift`, `runtimes.go` | |
| Cursor | Mac, Remote, web, server | broken (fails at turn) | 2026-10-17, 2026.10.01-e373342: failed at turn, in `.agents/reviews/runtimes/cursor-2026-10-17.md` | `RuntimeCatalog.swift`, `runtimes.go` | |
| Codex | Mac, Remote, web, server | broken (`ending`, `own_ask`, `scope`, `sessions`, `wait`, `workspaces` failed) | 2026-10-17, 2.2.2: assessment: 7 of 15 passed, in `.agents/reviews/runtimes/codex-2026-10-17.md` | `RuntimeCatalog.swift`, `runtimes.go`, `App/Resources/toolsets/codex/manifest.json`, `Go/internal/agentsd/brief.go` | `scope` and `permissions` fail on a root in `/tmp` (the nightly's): Codex's own `agent` mode (workspace-write) may write `/tmp` without asking, so no card comes (#1432). #1444, #1445 |
| Gemini | Mac, Remote, web, server | broken (fails at turn) | 2026-10-17, 0.64.0: failed at turn, in `.agents/reviews/runtimes/gemini-2026-10-17.md` | `RuntimeCatalog.swift`, `runtimes.go` | |
| Antigravity | Mac, Remote, web (Mac host only) | broken (fails at turn) | 2026-10-17, 1.4.1: failed at turn, in `.agents/reviews/runtimes/antigravity-2026-10-17.md` (skipped 2026-10-27: Antigravity not signed in on this Mac) | `RuntimeCatalog.swift`, `acp/session.go`, `App/Resources/toolsets/antigravity/manifest.json` | Brief as a session system prompt from 1.4.5 (#2613): the handshake and `session/new` were tested live on 2026-10-29, but no model turn ran, because the account's quota was spent |
| OpenCode | Mac, Remote, web, server | tested on a real account | 2026-10-22, 1.19.4: a real turn passed, not assessed, in `.agents/reviews/runtimes/opencode-2026-10-22.md` | `RuntimeCatalog.swift`, `runtimes.go` | |
<!-- runtimes:end -->

| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| Goose | — | removed (shelved, spec 050) | — | — | #44, closed as not planned |

## Runtime sign-in and allowance

How the app reads a runtime's account, its plan and what is left of it.
Open issues: `is:open label:integration allowance`.

| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| Claude plan windows | Mac, Remote, web | built | — | `Go/internal/agentsd/limits.go` | |
| Grok billing | Mac, Remote, web | built | — | `Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/Allowance/AllowanceReading.swift` | |
| Limits recognised from error text (Codex, Gemini, Copilot, Cursor) | Mac, Remote, web | built | — | `Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/Allowance/LimitRecognition.swift`, `Go/internal/agentsd/limits.go` | |
| Codex token refresh (auth.openai.com) | Mac, server | built | — | `Go/internal/mac/signin/codex.go` | |
| Gemini key check (generativelanguage.googleapis.com) | Mac | built | — | `Packages/AgentsKit/Sources/AgentsKitCore/Credentials/CredentialCheck.swift` | |
| OpenCode borrows the Mac's provider keys | Mac, server | built | — | `Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/LentFileSignIn.swift` | |
| More than one Claude account (`CLAUDE_CONFIG_DIR`) | Mac, Remote, web | built (walked on a scratch set-up with an account not signed in; not tested on a real second account) | 2026-10-21 | `Go/internal/agentsd/accounts.go` | Alex to test with two real sign-ins (#840) |
| More than one Codex account (`CODEX_HOME`) | Mac, Remote, web | built (not walked: no Codex on the walk's Mac) | 2026-10-21 | `Go/internal/agentsd/accounts.go` | Alex to test with two real sign-ins (#840) |

## Model gateways

An organisation's way to the model (#999): an org key or a gateway, kept on the control
plane and sent to machines sealed (`docs/explanation/org-keys-and-gateways.md`). Slice 1
keeps routes and sends them; slice 2 keeps them on the machine and reaches the model through
its relay. Slice 3 shows the routes to members on the Mac and the web page (#2283; the Remote's went with #2798).
Open issues: `is:open label:integration gateway`.

| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| Org key (Anthropic, OpenAI, Gemini, xAI) | control plane, machine; Mac, web | built | 2026-10-22, relay against a fake API; Claude, Codex, Gemini and OpenCode CLIs reach the relay | `Go/internal/controlplane/orgroutes.go`, `Go/internal/agentsd/modelrelay.go` | Alex to test with a real key (#2222) |
| Amazon Bedrock (API key, or access key and role by STS) | control plane, machine; Mac, web | built (Claude only) | 2026-10-22, STS, SigV4 and the event stream against fakes only | `Go/internal/controlplane/orgtokens.go`, `Go/internal/agentsd/modelrelay.go` | OpenCode not built; Alex to test with a real account (#2222) |
| Google Vertex AI (service account by OAuth) | control plane, machine; Mac, web | built (Claude, Gemini) | 2026-10-22, OAuth and the relay against fakes only | `Go/internal/controlplane/orgtokens.go`, `Go/internal/agentsd/modelrelay.go` | OpenCode not built; Alex to test with a real account (#2222) |
| Microsoft Azure (key, or Entra app) | control plane, machine; Mac, web | built | 2026-10-22, Entra and the relay against fakes only | `Go/internal/controlplane/orgtokens.go`, `Go/internal/agentsd/modelrelay.go` | Alex to test with a real account (#2222) |
| Base URL (LiteLLM, Portkey, …) | control plane, machine; Mac, web | built | 2026-10-22, relay against a fake API only | `Go/internal/controlplane/orgroutes.go`, `Go/internal/agentsd/modelrelay.go` | Alex to test with a real gateway (#2222) |

## Runtime downloads

What the app downloads to install or update a runtime.
Open issues: `is:open label:integration install`.

| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| Node from nodejs.org | Mac, server | built | — | `Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/Toolset.swift`, `Go/internal/controlplane/hostinstall/toolset.go` | |
| npm toolset locks | Mac, server | built | — | `scripts/update-toolset.sh` | |
| Antigravity from dl.google.com | Mac | built | — | `Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/ArchiveToolset.swift` | |
| OpenCode from GitHub releases | Mac, server | built | — | `Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/ArchiveToolset.swift` | |
| Grok, Copilot and Cursor install scripts | Mac, server | built | — | `App/Sources/AppModel+GetStarted.swift`, `Go/internal/agentsd/install.go` | |

## Machine providers

The machines hosts run on. The contract is in [Machine providers](machine-providers.md).
The presets are in `Go/internal/workspacecommands/presets.go` (Swift until #1364).
Open issues: `is:open label:integration workspace`.

| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| Docker | Mac, web, control plane | walked on scratch | 2026-10-19, on the Go control plane, Mac, Remote and web (`specs/691-workspace-providers/walks/857-go-docker.md`) | `presets.go` (`docker`) | CLI only, by decision on #1119 |
| Coder | Mac, web, control plane | built | 2026-10-19, API preset against a fake server only (#1119) | `presets.go` (`coder`, and `coder-api` through its API; `coder` still for ssh) | a walk with a real deployment |
| Codespaces | Mac, web, control plane | tested on a real account | 2026-10-19, a real codespace through both presets: Stop 34–38 s, Start online in 125 s (`specs/691-workspace-providers/walks/864-codespaces.md`) | `presets.go` (`codespaces`, and `codespaces-api` through its API; `gh` still for ssh) | #1643 |
| DigitalOcean | Mac, web, control plane | built | 2026-10-19, API preset (list, power on and off, create, delete) against a fake server only (#1119) | `presets.go` (`doctl`, and `digitalocean-api` through its API, nothing to install) | #865 |
| AWS EC2 | Mac, web, control plane | built | 2026-10-19, against a fake EC2 API only (#1345); SigV4 against AWS's own test vector | `presets.go` (`aws-ec2-api`, through its API, nothing to install), `aws.go` | a walk on a real account (Alex chooses it, #1345) |
| Google Compute Engine | Mac, web, control plane | tested on a real account | 2026-10-19, an e2-small VM in `agents-control` through the preset: create, install over ssh, Stop 16 s, Start online in 123 s, delete (`specs/691-workspace-providers/walks/1346-google-cloud.md`); against a fake API and token endpoint too | `presets.go` (`gcp-compute-api`, through its API, nothing to install), `google.go` | #1691 (an address that changes at Start) |
| Google Cloud Workstations | Mac, web, control plane | broken (Stop works, Start never brings the host back) | 2026-10-19, a real workstation in `agents-control`: list, install over ssh, link, Stop 7 s; Start fails on a new host key (`specs/691-workspace-providers/walks/1346-google-cloud.md`) | `presets.go` (`gcloud-workstations`) | #1701; CLI only |
| Any MCP or CLI provider (map written by an agent) | Mac, control plane | built | — | `Go/internal/controlplane/providers/drafts.go` | |
| The misbehaving fake provider | control plane | walked on scratch | 2026-10-19, on the Go control plane: a dropped tool and duplicate ids added | `connection_test.go` | |

## MCP and GitHub

Open issues: `is:open label:integration MCP`.

**Levels (#1428):** each connector reaches up to five levels: **Tools**, **Events**, **Views**,
**Workflows** and **Tested**. The host reads the first three from what the server declares
(`tools/list`, `events` in `initialize`, `ui://` views). Workflows is reached when a ready-made
workflow names one of the server's events (`ReadyMadeEvents`: `issue.labelled`,
`checks.failed` and `review.posted` since #1342, and `review.comment` for GitLab since #1633;
the workflows are in `Go/internal/agentsd/readymade/`). Tested is
reached when the `tested` field of the connector's entry in the Agents marketplace has a date
(`Go/internal/agentsd/mcpcatalog/agents.json`, #2155); set it in the same branch that changes the row's
state to `tested on a real account`. The Mac, the Remote and the web page show the levels on
every Connectors page, and the Mac's catalogue shows them on each row.

| Integration | Clients that show it | State | Levels | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- | --- |
| The github server (official github-mcp-server tools, our events, and views: Pull requests, Issues, a PR page with its diff, checks and review) | Mac, Remote, web, agents | tested on a real account | Tools, Events, Views, Workflows, Tested | 2026-10-19, the three ready-made workflows (#1342) on alexec/agents-walk, on a scratch host with a real device-flow sign-in: **Work an issue** (`issue.labelled` `agent` on #9 → a run at once, `create_pull_request` opened #10; `add_issue_comment` on an issue works since the App has Issues: Read and write, #11, #1601), **Fix failed checks** (`checks.failed` on #7 → the job log read, `greeting.txt` fixed in b1ed6d1, the check green again, a comment on the PR), **Address review comments** (`review.posted` on #8 → CodeRabbit's comment and a person's both fixed in bf7e2e7, each answered in its thread, a summary, `coderabbit_resolve`, the person's thread left open); 2026-10-18, views on alexec/agents-walk (#1341, `specs/071-web-remote/walks/1341/`): web walked through, Mac and iPhone drawn; 2026-10-18, its levels checked on a scratch host (#1428); 2026-10-24, cached MCP view tool refresh tested with a fake server (#2586); 2026-10-27, Issues page label colours and search (`show_issues` `labels`, `query`, `labelColors`) tested with a fake GitHub and the page in headless Chrome (#2686); 2026-10-16, side by side with the ci server it replaced (#1231) | `Go/cmd/github-mcp/main.go`, `Go/internal/githubmcp`, `Go/internal/agentsd` | the Mac's and the Remote's diff sheet unwalked (a walk can't press inside a view there); missing or unreadable view resources keep successful tool output visible (#2547); `mine` on checks.failed and pr.conflicted, `review.requested` and `issue.assigned` (#2034, for Notify me) tested with a fake GitHub only, not yet on a real account |
| CodeRabbit, through the github server (no CodeRabbit API or MCP server; known by its GitHub App `coderabbitai`): `review.posted` and `review.comment`, `coderabbit_review`, `coderabbit_reply` and `coderabbit_resolve`, and its block and marks on a PR's page | Mac, Remote, web, agents | tested on a real account | Tools, Events, Views, Workflows | 2026-10-19, Address review comments (#1342) on alexec/agents-walk PR #8: `review.posted` started it, its comment fixed and answered with `coderabbit_reply`, then `coderabbit_resolve`; a rate-limited or skipped review no longer raises `review.posted` (#1616); 2026-10-19, on alexec/agents-walk PR #1 (free tier, #1344): an answer in its thread and its reply as `review.comment`, `@coderabbitai review` refused on a reviewed commit, `full review` raised `review.posted`, `resolve`; the PR page drawn on the web (`specs/071-web-remote/walks/1344/`) | `Go/internal/githubmcp/coderabbit.go` | GitLab is 0.7 |
| GitHub Codespaces from Connectors ▸ Where agents run (#1591): the folder GitHub connection for API access, with GitHub CLI SSH config and the existing SSH host installer | Mac, web | built, tested with a fake GitHub | 2026-10-24, Go API and SSH config tests | `Go/internal/agentsd/codespaces.go`, `App/Sources/MCPServers/ConnectorSetupView.swift`, `Remote/Sources/MCPServers/RemoteConnectorSetup.swift`, `Web/src/views/ConnectorSetup.tsx` | Alex to approve Codespaces and Codespaces lifecycle permissions for `agents-loops` on github.com (#1591) |
| GitHub sign-in (GitHub App `agents-loops`, device flow, no `gh`): the **Connect GitHub** sheet, and Connectors ▸ Connections with Disconnect | Mac, web | walked on scratch | — | 2026-10-19, a real sign-in approved by Alex on github.com on a scratch host (#1336): the code on the Mac, the Remote and the web page, connected as alexec on Connectors; Disconnect's dialog drawn (it names the slots each folder loses), the disconnect itself sent as `connections/disconnect` (a walk can't press inside an AppKit alert): the Keychain item went and every GitHub slot waited again (`specs/1336-connect-your-tools/walks/`) | `Go/internal/connections`, `Go/internal/agentsd/connections.go`, `App/Sources/MCPServers/ConnectGitHubSheet.swift`, `Remote/Sources/MCPServers/RemoteConnectorSetup.swift`, `Web/src/views/ConnectorSetup.tsx` | |
| GitHub sign-up on the hosted service (#1807): the web redirect flow of the GitHub App `agents-loops`, its client secret on `agents-hosted` only; the token is used once to read the user's id and login, then forgotten | web (the sign-up and account pages at the hosted domain) | built, tested with a fake GitHub | — | — | `Go/internal/hosted`, `Go/cmd/agents-hosted`, `deploy/compose.hosted.yaml` | the App's callback URL `https://<domain>/signin/callback` and its client secret, then a real sign-up (Alex) |
| Connect your tools: a folder's set-up on its Connectors page (Tasks, Code review, CI from the GitHub connection, each proved by one read of the newest issue, the newest pull request and the last run; Where agents run = This Mac; the github events turned on once) | Mac, web | walked on scratch | — | 2026-10-19, on alexec/agents-walk with a real connection (#1336): Tasks read issue #6, Code review read PR #5, CI read (no runs there yet), 4 of 4; the install check said agents-loops holds no repositories, so the page showed the install link (`1336-mac-c-real-reads.png`) | `Go/internal/agentsd/connectorsetup.go`, `Go/internal/githubmcp/setup.go`, `App/Sources/MCPServers/ConnectorSetupView.swift` | Linear in Tasks (#1343); the events turned on by a real host, not yet seen (a scratch host has no personal ~/.agents, so the add was refused, as the page said) |
| Linear sign-in (OAuth app "Agents", authorization code with PKCE, no client secret): the **Connect Linear** sheet, the hand-back page at `agentloops.dev/oauth/callback`, and Connectors ▸ Connections with Disconnect | Mac, web | built | — | 2026-10-19, the hand-back page live at `https://agentloops.dev/oauth/callback` (`deploy/gcp/site.sh`): it answers with its strict headers, and every other address is 404 | `Go/internal/connections/linear.go`, `Go/internal/agentsd/connections.go`, `deploy/site/`, `App/Sources/MCPServers/ConnectLinearSheet.swift`, `Shared/UI/Connectors/CodeFlowSignIn.swift`, `Remote/Sources/MCPServers/RemoteConnectorSetup.swift`, `Web/src/views/ConnectorSetup.tsx` | a real sign-in not walked yet (#1343)
| GitLab sign-in (#1630): the device flow on gitlab.com (OAuth application "Agents" under agentstest, non-confidential, scope `api`, no client secret), or a personal access token on any GitLab, self-managed too; the **Connect GitLab** sheet and Connectors ▸ Connections with Disconnect; the gitlab server reads the connection, and sends its token only to the GitLab it was made on | Mac, web | tested on a real account | — | 2026-10-20, on gitlab.com as agentstest (#1634): the device flow with the Agents application (`connections/sign-in` → the code typed on gitlab.com/oauth/device, Authorize, Confirm → `connected`; Connectors says `GitLab · agentstest`, `OAuth · renews by itself`, `walks/1634/mac-0-gitlab-com-sign-in.png`), and the set-up read the folder with that connection; a personal access token too (its row says the token's own last day on the Mac, the Remote and the web page). Before that, against a fake GitLab only (`Go/internal/connections/gitlab_test.go`, `Go/internal/agentsd/connections_test.go`) | `Go/internal/connections/gitlab.go`, `Go/internal/agentsd/connections.go`, `Go/cmd/gitlab-mcp/main.go`, `App/Sources/MCPServers/ConnectGitLabSheet.swift`, `Remote/Sources/MCPServers/RemoteConnectorSetup.swift`, `Web/src/views/ConnectorSetup.tsx` | the device flow driven through the host's calls, not by pressing **gitlab.com** in a client's sheet (that opens the person's own browser) |
| Email sign-in (#1780): the **Connect Email** sheet (an IMAP server, a user and an app password; the host signs in once to check them and keeps them in its store, never in a log or an answer) and Connectors ▸ Connections with Disconnect; the email server reads the connection | Mac, web | built | — | 2026-10-20, against a stand-in check in `Go/internal/agentsd/connections_test.go` and go-imap's in-memory server (`Go/internal/emailmcp`) | `Go/internal/connections/email.go`, `Go/internal/agentsd/connections.go`, `App/Sources/MCPServers/ConnectEmailSheet.swift`, `Remote/Sources/MCPServers/RemoteConnectorSetup.swift`, `Web/src/views/ConnectorSetup.tsx` | a real mailbox (Alex's step on #1780) |
| Connect your tools with GitLab (#1632): a folder with a GitLab remote gets Tasks, Code review and CI from the GitLab connection, each proved by one read (the newest issue, the newest merge request, the last pipeline), and the gitlab server's events turned on once | Mac, web | tested on a real account | — | 2026-10-20, agentstest-group/agents-walk on a scratch host (#1634): the three slots read the newest issue, the newest merge request and the last pipeline, and the gitlab connector was added to the folder's `.agents/mcp.json` with its events on; drawn on the Mac, the Remote and the web page (`specs/071-web-remote/walks/1634/`). Before that, against a fake GitLab only (`TestAGitLabProjectsConnectorSetUp`, `Go/internal/gitlabmcp/setup_test.go`) | `Go/internal/agentsd/connectorsetup.go`, `Go/internal/gitlabmcp/setup.go`, `App/Sources/MCPServers/ConnectorSetupView.swift`, `Remote/Sources/MCPServers/RemoteConnectorSetup.swift`, `Web/src/views/ConnectorSetup.tsx` |  |
| The linear server (`show_issues` and the **Linear issues** page with Start Agent, and events; the Linear connection or `LINEAR_API_KEY`). Changes to issues are Linear's own server's (`mcp.linear.app`, from the marketplace) | Mac, Remote, web, agents | tested on a real account | Tools, Events, Views, Workflows (**Work a Linear issue**, `Go/internal/agentsd/readymade/work-a-linear-issue/`), Tested | 2026-10-19, on Alex's workspace (team AGE) with the personal API key (#1343): `show_issues` listed the team's 4 open issues; a test issue AGE-8 raised `issue.opened`, and the Bug label added after five minutes raised `issue.labelled`; AGE-8 deleted after. Before that, the Linear issues page walked on a scratch host with a stand-in Linear: the web page through Start Agent (`specs/071-web-remote/walks/1343/`), the Mac's view by the host's log | `Go/cmd/linear-mcp/main.go`, `Go/internal/linearmcp` | the workflow not run on a real issue; the Remote's page unwalked; its video, `scripts/video/scenes/i-linear.py` (#1794), not made yet: Alex signs in to the video Chrome first (#1793); `issue.assigned` (#2034, for Notify me) tested with recorded answers only, not yet on a real workspace
| The gitlab server (our tools, events and views — Merge requests, Issues, a merge request's page with its diff and pipeline — on REST v4, not GitLab's own MCP server; gitlab.com or a self-managed GitLab by `GITLAB_URL`, the GitLab connection or `GITLAB_TOKEN`) | Mac, Remote, web, agents | tested on a real account | Tools, Events, Views, Workflows (**Work an issue**, **Fix failed checks**, **Address review comments**, #1633), Tested | 2026-10-20, on agentstest-group/agents-walk with a personal access token (#1634): every tool, and each of the ten events raised by a real change; the three ready-made workflows on a scratch host: **Work an issue** (`issue.labelled` `agent` on #3 → `get_issue`, a branch, `create_merge_request` opened !5, `comment_on_issue`), **Address review comments** (`review.comment` on a line of !4 → fixed in a commit, answered in its thread, a summary), **Fix failed checks** (`checks.failed` on !1 → no job log, so no fix pushed, and a comment that says why); the views drawn on the Mac, the Remote and the web page. 2026-10-19, against a fake GitLab (#1629), and its views in headless Chrome (#1631, `specs/071-web-remote/walks/1631/`) | `Go/cmd/gitlab-mcp/main.go`, `Go/internal/gitlabmcp` | gitlab.com runs no pipeline for agentstest until its identity is verified, so **Fix failed checks** has not read a real failed job's log yet; `mine` on checks.failed and pr.conflicted, `review.requested` and `issue.assigned` (#2034, for Notify me) tested with a fake GitLab only, not yet on a real account |
| The email server (#1780): one IMAP mailbox (go-imap v2, with IDLE), the event `email.received` (filters `from`, `to`, `subject`, `folder`, `authenticated`; its data never has the text; its `sender` carries the From address and the aligned DKIM pass, for a channel link, #1762), and `list_folders`, `list_messages`, `search_messages`, `read_message` (the text marked as outside content), `mark_read` and `move_message`; read-only, it never sends; the email connection or `EMAIL_IMAP_URL`, `EMAIL_USER` and `EMAIL_PASSWORD`; Agents Host carries it, every Linux host installs it, and the catalogue lists it as `agents/email` in the Agents marketplace | Mac, Remote, web, agents | built | Tools, Events, Views (**Mail**, `show_mail`), Workflows (**Answer a sign-up code**, `Go/internal/agentsd/readymade/answer-a-sign-up-code/`) | 2026-10-20, against go-imap's in-memory IMAP server only (`Go/internal/emailmcp`), and a stand-in for walks (`Go/internal/emailmcp/walk`) | `Go/cmd/email-mcp/main.go`, `Go/internal/emailmcp` | a real mailbox, and the workflow run on a real sign-up code: Alex's test on #1780 |
| MCP OAuth | Mac | built | — | — | `Go/internal/agentsd/mcpcatalog/oauth.go`, `App/Sources/Catalog/MCPSignInSheet.swift` | |
| Events from MCP servers (polling only) | Mac, Remote, web | built | — | — | `Go/internal/agentsd/mcpevents.go` | |
| Git credentials lent from the Mac to a Linux host | Mac, server | built | — | — | `App/Sources/Hosts/Lending.swift` | |

## Marketplaces and catalogues

Open issues: `is:open label:integration marketplace`.

| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| GitHub MCP registry | Mac | built | — | `Go/internal/agentsd/mcpcatalog/registry.go` | |
| registry.modelcontextprotocol.io | Mac | built | — | `MCPRegistryEndpoints.swift`, `Go/internal/agentsd/mcpcatalog/registry.go` | |
| skills.sh | Mac | built | — | `Go/internal/agentsd/catalog.go`, `App/Sources/Catalog/AddSkillSheet.swift` | |
| GitHub skill and plugin sources | Mac | built | — | `Go/internal/agentsd/skillcatalog/github.go` | |
| Custom marketplaces with a token | Mac | built | — | `Go/internal/agentsd/skillcatalog/marketplaces.go` | |
| The Agents marketplace: the connectors Agents makes, a file every host carries (#2155) | Mac | built | 2026-10-22, the Mac's catalogue on a scratch root (`specs/071-web-remote/walks/2155/`) | `Go/internal/agentsd/mcpcatalog/agents.json`, `filemarket.go` | |
| A marketplace that is a file or a folder, personal or a folder's (#2155) | Mac | built | 2026-10-22, tested only (`TestAFileMarketplaceIsSearchedAndAdded`) | `Go/internal/agentsd/mcpcatalog/filemarket.go` | |

## Notifications and links

Open issues: `is:open label:integration notification`.

| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| CloudKit mailbox push | Remote | built | — | `Packages/AgentsKit/Sources/AgentsKitCore/Remote/CloudKitMailbox.swift`, `RemoteNotify/Sources/NotificationService.swift` | |
| APNs from the control plane (#1460) | Remote | built, not working live (#1509) | 2026-10-18, live on control.agentloops.dev with the real key: no push with the relay off, two tries (`specs/058-control-plane/walks/1461.md`) | `Go/internal/controlplane/apns/`, `Go/internal/controlplane/push.go`, `Packages/AgentsKit/Sources/AgentsKitCore/Remote/ControlPush.swift` | #1509 (fix in v0.5.1) |
| Live Activity updates by APNs (#1744) | Remote | built, not walked | — | `Go/internal/controlplane/activities.go`, `Go/internal/controlplane/apns/`, `Go/internal/agentsd/turnphase.go`, `Remote/Sources/Notifications/TurnActivities.swift` | Alex's test on a device |
| CloudKit relay channel (Remote to Mac) | Remote, Mac | built | — | `Packages/AgentsKit/Sources/AgentsKit/Relay/ControlRelay.swift`, `Host/Relay/Sources/main.swift` | |
| Local notifications | Mac, Remote | built | — | `App/Sources/Notifications/MacNotifier.swift`, `Remote/Sources/Notifications/DeviceNotifier.swift` | |
| The attention widget | Remote | built | — | `RemoteWidget/Sources/AttentionWidget.swift` | |

## Control plane hosting

Open issues: `is:open label:integration "control plane"`.

| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| S3 or MinIO store | control plane, Mac | built | — | `Go/internal/controlplane/s3store/s3store.go`, `Host/Sources/StoreChoice.swift` | |
| KMS (local, HashiCorp Vault, Google Cloud KMS) | control plane | built | — | `Go/internal/controlplane/kms/kms.go` | |
| Caddy with ACME | control plane | tested on a real account | 2026-10-18, Let's Encrypt certificates for control.agentloops.dev and views.agentloops.dev (`specs/058-control-plane/walks/1461.md`) | `deploy/` | |
| Bonjour discovery | Mac, control plane | built | — | `Host/Sources/LocalServices.swift`, `Go/internal/controlplane/machine.go` | |
| ssh host install and tunnels | Mac, server, control plane | built | — | `Go/internal/controlplane/hostinstall/ssh.go`, `Go/internal/controlplane/hosttunnels/ssh.go` | |
| Audit sinks: syslog (RFC 5424 over TCP or TLS) and HTTP (JSON lines, a bearer token) to a SIEM (#1001) | web (Console ▸ Audit ▸ Sinks), control plane | built | 2026-10-22, against a local TCP, TLS and HTTP listener in tests only | `Go/internal/controlplane/audit/sink.go`, `Go/internal/controlplane/auditing_sinks.go`, `Web/src/views/AuditSinks.tsx` | Alex to test with a real SIEM (#2222) |
| OTLP metrics: the report figures (cost, tokens, sessions, pull requests, workflow runs, time) by runtime to an OpenTelemetry collector over OTLP/HTTP JSON (#2019) | control plane (`OTEL_EXPORTER_OTLP_ENDPOINT`), web (Console ▸ Read API shows its state) | built | 2026-10-22, against a local HTTP collector in tests only | `Go/internal/controlplane/otlp.go` | Alex to test with a real collector (#2222) |
| Read API for BI tools: `GET /v1/read/reports` with an admin's token, JSON, CSV or JSON lines (#2019) | web (Console ▸ Read API), control plane | built | 2026-10-22, with curl on a scratch control plane | `Go/internal/controlplane/readapi.go`, `Web/src/views/ReadAPI.tsx` | Alex to test with a real BI tool (#2222) |
| Google Cloud (Compute Engine VM and Cloud KMS) for the control plane | control plane | tested on a real account | 2026-10-18, `up.sh` made the VM `agents-control`, the live control plane moved there and back (`specs/058-control-plane/walks/1461.md`) | `deploy/gcp/up.sh`, `deploy/gcp/down.sh`, `deploy/gcp/startup.sh` | |
| Cloudflare DNS for the control plane's names | control plane | tested on a real account | 2026-10-18, `dns.sh` made the A records for control.agentloops.dev and views.agentloops.dev (`specs/058-control-plane/walks/1461.md`) | `deploy/cloudflare/dns.sh` | |
| Cloudflare Pages for the promotional site, www.agentloops.dev | none (the public site) | built | — | `.github/workflows/www-publish.yml`, `www/` | #1550: the Pages token is Alex's |

## Signing a person in to the control plane

Open issues: `is:open label:integration sign-in`. Not a runtime's sign-in or a connector's: this is how a person pairs a client with no code, or adds a sign-in to themselves (#995, spec 736 T2). The client ids are the app's own (`Go/internal/controlplane/signin/config.go`, or `AGENTS_SIGNIN_*` on the control plane), so no operator registers anything. An org provider (#1002) is the exception: the organisation registers its own client for its control plane ([Sign-in providers](sign-in.md)).

| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| Sign in with Google (an ID token from the app's Google OAuth client, checked against Google's JWKS, `iss`, `aud`, the expiry and a nonce bound to the control plane's key id and the hello; allowed Workspace domains) | Mac, Remote, web (settings only), control plane | built, tested with a fake issuer | 2026-10-21, `Go/internal/controlplane/signin_test.go` and `signin/signin_test.go` (every refusal, a replay to a second control plane, key rotation) | `Go/internal/controlplane/signin/oidc.go`, `Go/internal/controlplane/signin.go`, `Shared/UI/SignIn/SignInButtons.swift`, `Packages/AgentsKit/Sources/AgentsKitCore/Model/IdentityProviders.swift` | the Google OAuth client (Alex, #995); a real sign-in, unwalked |
| Sign in with Apple (a native `ASAuthorizationAppleIDProvider` ID token, checked against Apple's JWKS; invite only) | Mac, Remote, web (settings only), control plane | built, on: the capability on both App IDs and the entitlement (#2507); tested with a fake issuer | 2026-10-23, the entitlement signed into a development build | `Go/internal/controlplane/signin/oidc.go`, `Go/internal/controlplane/signin.go`, `App/Agents-Store.entitlements` | a real sign-in on a device (Alex, #2031); the App Store profiles made again |
| Sign in with GitHub (the device flow of a sign-in GitHub App with user tokens that expire; `GET /user` once, then the token is forgotten; allowed organisations; each further client approved on a card) | Mac, Remote, web (the card and settings), control plane | built, tested with a fake GitHub | 2026-10-21, `Go/internal/controlplane/signin_test.go` (the approval, a replay to a second control plane, organisations, no token in the store or the log) | `Go/internal/controlplane/signin/github.go`, `Go/internal/controlplane/signin_approvals.go` | the GitHub App (Alex, #995); a real sign-in, unwalked |
| Org provider, generic OIDC (an organisation's own issuer: the control plane is the confidential client, code flow with PKCE, the client secret sealed with the keeper; a ticket for one use pairs the client; claimed domains by DNS TXT; #1002) | control plane (Mac, Remote and web screens with #1002 slice 3) | built, tested with a fake provider | 2026-10-22, `Go/internal/controlplane/signin_org_test.go` with the fake provider (RS256 and ES256, every refusal, a ticket on another connection, two copies, no secret or token in the store) | `Go/internal/controlplane/signin_org.go`, `Go/internal/controlplane/identity_oidc_http.go`, `Go/internal/controlplane/signin/discovery.go`, `Go/internal/controlplane/signin_domains.go` | a real provider, unwalked; no client screens yet (#1002 slice 3) |
| Okta as an org provider (preset `okta`: the account is `sub`) | control plane | built, tested with a fake provider | 2026-10-22, `Go/internal/controlplane/signin_org_test.go` with the fake provider (RS256 and ES256, every refusal, a ticket on another connection, two copies, no secret or token in the store) | `Go/internal/controlplane/signin_org.go`, `Go/internal/controlplane/identity_oidc_http.go`, `Go/internal/controlplane/signin/discovery.go` | a real Okta tenant (Alex, #2222) |
| Microsoft Entra ID as an org provider (preset `entra`: the account is `oid`, `tid` must be the tenant) | control plane | built, tested with a fake provider | 2026-10-22, `Go/internal/controlplane/signin_org_test.go` with the fake provider (RS256 and ES256, every refusal, a ticket on another connection, two copies, no secret or token in the store) | `Go/internal/controlplane/signin_org.go`, `Go/internal/controlplane/identity_oidc_http.go`, `Go/internal/controlplane/signin/discovery.go` | a real Entra tenant (Alex, #2222) |
| SCIM 2.0 for Okta and Entra (`/scim/v2/`: users, groups, PATCH, suspension; the refresh check without SCIM) | control plane | built, tested with request sets written from the vendors' docs | 2026-10-22, `Go/internal/controlplane/scim_test.go` (the Okta and Entra sets in `scim/testdata/`, tokens, suspension on two copies in 5 s, roles from groups, refresh checks, 5,000 users at p95 under 200 ms) | `Go/internal/controlplane/scim/`, `people_scim.go`, `groups_scim.go`, `scim_tokens.go`, `orgrefresh.go` | the request sets recorded on real Okta and Entra tenants, and a deactivation walked (Alex, #2222); machines (slice 2b), clients and Console (slices 3, 4) |
| Google Workspace with the organisation's own client, as an org provider (preset `googleWorkspace`: `hd` must be a proved domain) | control plane | built, tested with a fake provider | 2026-10-22, `Go/internal/controlplane/signin_org_test.go` with the fake provider (RS256 and ES256, every refusal, a ticket on another connection, two copies, no secret or token in the store) | `Go/internal/controlplane/signin_org.go`, `Go/internal/controlplane/identity_oidc_http.go`, `Go/internal/controlplane/signin/discovery.go` | a real Workspace (Alex, #2222) |

## The docs site

Where these pages are published. Open issues: `is:open label:integration docs`.

| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| GitHub Pages for the docs site at docs.agentloops.dev (#1549): built and published by `docs-publish` from `main`, with a Let's Encrypt certificate and HTTPS enforced; old `alexec.github.io/Agents/<path>` links go to the same path with a 301; the Mac's **Help ▸ Agents Help**, the Remote's **Help** in Settings and the web page's **Help** open it | Mac, Remote, web | tested on a real account | 2026-10-21, served at `https://docs.agentloops.dev/` with its certificate, and the old links redirect (`.agents/reviews/docs-site-poc-2026-10-21.md`) | `.github/workflows/docs-publish.yml`, `scripts/docs.sh`, `docs/CNAME`, `Shared/UI/HelpSite.swift`, `Web/src/views/Sidebar.tsx` | |
| Cloudflare DNS for the docs site: the CNAME `docs` to `alexec.github.io`, DNS only | — | tested on a real account | 2026-10-21, made by `dns.sh --names docs --cname alexec.github.io` (#1914) | `deploy/cloudflare/dns.sh` | |

## Model gateways

Open issues: `is:open label:integration gateway`.

| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| Environment variables passed through (Bedrock, Vertex, base URL) | Mac, server | built | — | `Go/internal/agentsd/runtimes.go` | #999 |
| Org keys and gateways | control plane, machine | built (see above) | 2026-10-22 | `Go/internal/agentsd/orgroutes.go` | #999 |

## Planned (no code)

Open issues: `is:open label:integration`.

| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| Forgejo | — | planned | — | — | #813 |
| Google Chat | — | planned (parked) | — | — | #1016 |

## Removed

| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| Slack and the Channels layer | — | removed | 2026-10-16, PR #1230 | — | #1223, closed |
