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
| Grok | Mac, Remote, web, server | broken (fails at handshake) | 2026-10-17, 1.0.52: failed at handshake, in `.agents/reviews/runtimes/grok-2026-10-17.md` | `RuntimeCatalog.swift`, `runtimes.go` | |
| Copilot | Mac, Remote, web, server | broken (fails at turn) | 2026-10-17, 1.0.93-1: failed at turn, in `.agents/reviews/runtimes/copilot-2026-10-17.md` (skipped 2026-10-20: Copilot its allowance is spent on this Mac) | `RuntimeCatalog.swift`, `runtimes.go` | |
| Cursor | Mac, Remote, web, server | broken (fails at turn) | 2026-10-17, 2026.10.01-e373342: failed at turn, in `.agents/reviews/runtimes/cursor-2026-10-17.md` | `RuntimeCatalog.swift`, `runtimes.go` | |
| Codex | Mac, Remote, web, server | broken (`ending`, `own_ask`, `scope`, `sessions`, `wait`, `workspaces` failed) | 2026-10-17, 2.2.2: assessment: 7 of 15 passed, in `.agents/reviews/runtimes/codex-2026-10-17.md` | `RuntimeCatalog.swift`, `runtimes.go` | `scope` and `permissions` fail on a root in `/tmp` (the nightly's): Codex's own `agent` mode (workspace-write) may write `/tmp` without asking, so no card comes (#1432). #1444, #1445 |
| Gemini | Mac, Remote, web, server | broken (fails at turn) | 2026-10-17, 0.64.0: failed at turn, in `.agents/reviews/runtimes/gemini-2026-10-17.md` | `RuntimeCatalog.swift`, `runtimes.go` | |
| Antigravity | Mac, Remote, web (Mac host only) | broken (fails at turn) | 2026-10-17, 1.4.1: failed at turn, in `.agents/reviews/runtimes/antigravity-2026-10-17.md` | `RuntimeCatalog.swift` | |
| OpenCode | Mac, Remote, web, server | broken (`workspaces` failed) | 2026-10-17, 1.19.3: assessment: 12 of 15 passed, in `.agents/reviews/runtimes/opencode-2026-10-17.md` | `RuntimeCatalog.swift`, `runtimes.go` | |
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

## Workspace providers

The machines hosts run on. The contract is in [Workspace providers](workspace-providers.md).
The presets are in `Go/internal/workspacecommands/presets.go` (Swift until #1364).
Open issues: `is:open label:integration workspace`.

| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| Docker | Mac, Remote, web, control plane | walked on scratch | 2026-10-19, on the Go control plane, Mac, Remote and web (`specs/691-workspace-providers/walks/857-go-docker.md`) | `presets.go` (`docker`) | CLI only, by decision on #1119 |
| Coder | Mac, Remote, web, control plane | built | 2026-10-19, API preset against a fake server only (#1119) | `presets.go` (`coder`, and `coder-api` through its API; `coder` still for ssh) | a walk with a real deployment |
| Codespaces | Mac, Remote, web, control plane | tested on a real account | 2026-10-19, a real codespace through both presets: Stop 34–38 s, Start online in 125 s (`specs/691-workspace-providers/walks/864-codespaces.md`) | `presets.go` (`codespaces`, and `codespaces-api` through its API; `gh` still for ssh) | #1643 |
| DigitalOcean | Mac, Remote, web, control plane | built | 2026-10-19, API preset (list, power on and off, create, delete) against a fake server only (#1119) | `presets.go` (`doctl`, and `digitalocean-api` through its API, nothing to install) | #865 |
| AWS EC2 | Mac, Remote, web, control plane | built | 2026-10-19, against a fake EC2 API only (#1345); SigV4 against AWS's own test vector | `presets.go` (`aws-ec2-api`, through its API, nothing to install), `aws.go` | a walk on a real account (Alex chooses it, #1345) |
| Google Compute Engine | Mac, Remote, web, control plane | tested on a real account | 2026-10-19, an e2-small VM in `agents-control` through the preset: create, install over ssh, Stop 16 s, Start online in 123 s, delete (`specs/691-workspace-providers/walks/1346-google-cloud.md`); against a fake API and token endpoint too | `presets.go` (`gcp-compute-api`, through its API, nothing to install), `google.go` | #1691 (an address that changes at Start) |
| Google Cloud Workstations | Mac, Remote, web, control plane | broken (Stop works, Start never brings the host back) | 2026-10-19, a real workstation in `agents-control`: list, install over ssh, link, Stop 7 s; Start fails on a new host key (`specs/691-workspace-providers/walks/1346-google-cloud.md`) | `presets.go` (`gcloud-workstations`) | #1701; CLI only |
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
reached when the `Tested` field of the connector's catalogue entry has a date
(`Go/internal/agentsd/mcpcatalog/ours.go`); set it in the same branch that changes the row's
state to `tested on a real account`. The Mac, the Remote and the web page show the levels on
every Connectors page, and the Mac's catalogue shows them on each row.

| Integration | Clients that show it | State | Levels | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- | --- |
| The github server (official github-mcp-server tools, our events, and views: Pull requests, Issues, a PR page with its diff, checks and review), Made by Agents | Mac, Remote, web, agents | tested on a real account | Tools, Events, Views, Workflows, Tested | 2026-10-19, the three ready-made workflows (#1342) on alexec/agents-walk, on a scratch host with a real device-flow sign-in: **Work an issue** (`issue.labelled` `agent` on #9 → a run at once, `create_pull_request` opened #10; `add_issue_comment` on an issue works since the App has Issues: Read and write, #11, #1601), **Fix failed checks** (`checks.failed` on #7 → the job log read, `greeting.txt` fixed in b1ed6d1, the check green again, a comment on the PR), **Address review comments** (`review.posted` on #8 → CodeRabbit's comment and a person's both fixed in bf7e2e7, each answered in its thread, a summary, `coderabbit_resolve`, the person's thread left open); 2026-10-18, views on alexec/agents-walk (#1341, `specs/071-web-remote/walks/1341/`): web walked through, Mac and iPhone drawn; 2026-10-18, its levels checked on a scratch host (#1428); 2026-10-16, side by side with the ci server it replaced (#1231) | `Go/cmd/github-mcp/main.go`, `Go/internal/githubmcp` | the Mac's and the Remote's diff sheet unwalked (a walk can't press inside a view there) |
| CodeRabbit, through the github server (no CodeRabbit API or MCP server; known by its GitHub App `coderabbitai`): `review.posted` and `review.comment`, `coderabbit_review`, `coderabbit_reply` and `coderabbit_resolve`, and its block and marks on a PR's page | Mac, Remote, web, agents | tested on a real account | Tools, Events, Views, Workflows | 2026-10-19, Address review comments (#1342) on alexec/agents-walk PR #8: `review.posted` started it, its comment fixed and answered with `coderabbit_reply`, then `coderabbit_resolve`; a rate-limited or skipped review no longer raises `review.posted` (#1616); 2026-10-19, on alexec/agents-walk PR #1 (free tier, #1344): an answer in its thread and its reply as `review.comment`, `@coderabbitai review` refused on a reviewed commit, `full review` raised `review.posted`, `resolve`; the PR page drawn on the web (`specs/071-web-remote/walks/1344/`) | `Go/internal/githubmcp/coderabbit.go` | GitLab is 0.7 |
| GitHub sign-in (GitHub App `agents-loops`, device flow, no `gh`): the **Connect GitHub** sheet, and Your Connectors ▸ Connections with Disconnect | Mac, Remote, web | walked on scratch | — | 2026-10-19, a real sign-in approved by Alex on github.com on a scratch host (#1336): the code on the Mac, the Remote and the web page, connected as alexec on Your Connectors; Disconnect's dialog drawn (it names the slots each project loses), the disconnect itself sent as `connections/disconnect` (a walk can't press inside an AppKit alert): the Keychain item went and every GitHub slot waited again (`specs/1336-connect-your-tools/walks/`) | `Go/internal/connections`, `Go/internal/agentsd/connections.go`, `App/Sources/MCPServers/ConnectGitHubSheet.swift`, `Remote/Sources/MCPServers/RemoteConnectorSetup.swift`, `Web/src/views/ConnectorSetup.tsx` | |
| Connect your tools: a project's set-up on its Connectors page (Tasks, Code review, CI from the GitHub connection, each proved by one read of the newest issue, the newest pull request and the last run; Where agents run = This Mac; the github events turned on once) | Mac, Remote, web | walked on scratch | — | 2026-10-19, on alexec/agents-walk with a real connection (#1336): Tasks read issue #6, Code review read PR #5, CI read (no runs there yet), 4 of 4; the install check said agents-loops holds no repositories, so the page showed the install link (`1336-mac-c-real-reads.png`) | `Go/internal/agentsd/connectorsetup.go`, `Go/internal/githubmcp/setup.go`, `App/Sources/MCPServers/ConnectorSetupView.swift` | Codespaces in Where agents run (#1591); Linear in Tasks (#1343); the events turned on by a real host, not yet seen (a scratch host has no personal ~/.agents, so the add was refused, as the page said) |
| Linear sign-in (OAuth app "Agents", authorization code with PKCE, no client secret): the **Connect Linear** sheet, the hand-back page at `agentloops.dev/oauth/callback`, and Your Connectors ▸ Connections with Disconnect | Mac, Remote, web | built | — | 2026-10-19, the hand-back page live at `https://agentloops.dev/oauth/callback` (`deploy/gcp/site.sh`): it answers with its strict headers, and every other address is 404 | `Go/internal/connections/linear.go`, `Go/internal/agentsd/connections.go`, `deploy/site/`, `App/Sources/MCPServers/ConnectLinearSheet.swift`, `Shared/UI/Connectors/CodeFlowSignIn.swift`, `Remote/Sources/MCPServers/RemoteConnectorSetup.swift`, `Web/src/views/ConnectorSetup.tsx` | a real sign-in not walked yet (#1343)
| GitLab sign-in (#1630): the device flow on gitlab.com (OAuth application "Agents" under agentstest, non-confidential, scope `api`, no client secret), or a personal access token on any GitLab, self-managed too; the **Connect GitLab** sheet and Your Connectors ▸ Connections with Disconnect; the gitlab server reads the connection, and sends its token only to the GitLab it was made on | Mac, Remote, web | tested on a real account | — | 2026-10-20, on gitlab.com as agentstest (#1634): the device flow with the Agents application (`connections/sign-in` → the code typed on gitlab.com/oauth/device, Authorize, Confirm → `connected`; Your Connectors says `GitLab · agentstest`, `OAuth · renews by itself`, `walks/1634/mac-0-gitlab-com-sign-in.png`), and the set-up read the project with that connection; a personal access token too (its row says the token's own last day on the Mac, the Remote and the web page). Before that, against a fake GitLab only (`Go/internal/connections/gitlab_test.go`, `Go/internal/agentsd/connections_test.go`) | `Go/internal/connections/gitlab.go`, `Go/internal/agentsd/connections.go`, `Go/cmd/gitlab-mcp/main.go`, `App/Sources/MCPServers/ConnectGitLabSheet.swift`, `Remote/Sources/MCPServers/RemoteConnectorSetup.swift`, `Web/src/views/ConnectorSetup.tsx` | the device flow driven through the host's calls, not by pressing **gitlab.com** in a client's sheet (that opens the person's own browser) |
| Email sign-in (#1780): the **Connect Email** sheet (an IMAP server, a user and an app password; the host signs in once to check them and keeps them in its store, never in a log or an answer) and Your Connectors ▸ Connections with Disconnect; the email server reads the connection | Mac, Remote, web | built | — | 2026-10-20, against a stand-in check in `Go/internal/agentsd/connections_test.go` and go-imap's in-memory server (`Go/internal/emailmcp`) | `Go/internal/connections/email.go`, `Go/internal/agentsd/connections.go`, `App/Sources/MCPServers/ConnectEmailSheet.swift`, `Remote/Sources/MCPServers/RemoteConnectorSetup.swift`, `Web/src/views/ConnectorSetup.tsx` | a real mailbox (Alex's step on #1780) |
| Connect your tools with GitLab (#1632): a project with a GitLab remote gets Tasks, Code review and CI from the GitLab connection, each proved by one read (the newest issue, the newest merge request, the last pipeline), and the gitlab server's events turned on once | Mac, Remote, web | tested on a real account | — | 2026-10-20, agentstest-group/agents-walk on a scratch host (#1634): the three slots read the newest issue, the newest merge request and the last pipeline, and the gitlab connector was added to the project's `.agents/mcp.json` with its events on; drawn on the Mac, the Remote and the web page (`specs/071-web-remote/walks/1634/`). Before that, against a fake GitLab only (`TestAGitLabProjectsConnectorSetUp`, `Go/internal/gitlabmcp/setup_test.go`) | `Go/internal/agentsd/connectorsetup.go`, `Go/internal/gitlabmcp/setup.go`, `App/Sources/MCPServers/ConnectorSetupView.swift`, `Remote/Sources/MCPServers/RemoteConnectorSetup.swift`, `Web/src/views/ConnectorSetup.tsx` |  |
| The linear server (`show_issues` and the **Linear issues** page with Start Agent, and events; the Linear connection or `LINEAR_API_KEY`), Made by Agents. Changes to issues are Linear's own server's (`mcp.linear.app`, from the marketplace) | Mac, Remote, web, agents | tested on a real account | Tools, Events, Views, Workflows (**Work a Linear issue**, `Go/internal/agentsd/readymade/work-a-linear-issue/`), Tested | 2026-10-19, on Alex's workspace (team AGE) with the personal API key (#1343): `show_issues` listed the team's 4 open issues; a test issue AGE-8 raised `issue.opened`, and the Bug label added after five minutes raised `issue.labelled`; AGE-8 deleted after. Before that, the Linear issues page walked on a scratch host with a stand-in Linear: the web page through Start Agent (`specs/071-web-remote/walks/1343/`), the Mac's view by the host's log | `Go/cmd/linear-mcp/main.go`, `Go/internal/linearmcp` | the workflow not run on a real issue; the Remote's page unwalked; its video, `scripts/video/scenes/i-linear.py` (#1794), not made yet: Alex signs in to the video Chrome first (#1793)
| The gitlab server (our tools, events and views — Merge requests, Issues, a merge request's page with its diff and pipeline — on REST v4, not GitLab's own MCP server; gitlab.com or a self-managed GitLab by `GITLAB_URL`, the GitLab connection or `GITLAB_TOKEN`), Made by Agents | Mac, Remote, web, agents | tested on a real account | Tools, Events, Views, Workflows (**Work an issue**, **Fix failed checks**, **Address review comments**, #1633), Tested | 2026-10-20, on agentstest-group/agents-walk with a personal access token (#1634): every tool, and each of the ten events raised by a real change; the three ready-made workflows on a scratch host: **Work an issue** (`issue.labelled` `agent` on #3 → `get_issue`, a branch, `create_merge_request` opened !5, `comment_on_issue`), **Address review comments** (`review.comment` on a line of !4 → fixed in a commit, answered in its thread, a summary), **Fix failed checks** (`checks.failed` on !1 → no job log, so no fix pushed, and a comment that says why); the views drawn on the Mac, the Remote and the web page. 2026-10-19, against a fake GitLab (#1629), and its views in headless Chrome (#1631, `specs/071-web-remote/walks/1631/`) | `Go/cmd/gitlab-mcp/main.go`, `Go/internal/gitlabmcp` | gitlab.com runs no pipeline for agentstest until its identity is verified, so **Fix failed checks** has not read a real failed job's log yet |
| The email server (#1780): one IMAP mailbox (go-imap v2, with IDLE), the event `email.received` (filters `from`, `to`, `subject`, `folder`, `authenticated`; its data never has the text), and `list_folders`, `list_messages`, `search_messages`, `read_message` (the text marked as outside content), `mark_read` and `move_message`; read-only, it never sends; the email connection or `EMAIL_IMAP_URL`, `EMAIL_USER` and `EMAIL_PASSWORD`; Agents Host carries it, every Linux host installs it, and the catalogue lists it as `agents/email`, Made by Agents | Mac, Remote, web, agents | built | Tools, Events, Views (**Mail**, `show_mail`), Workflows (**Answer a sign-up code**, `Go/internal/agentsd/readymade/answer-a-sign-up-code/`) | 2026-10-20, against go-imap's in-memory IMAP server only (`Go/internal/emailmcp`), and a stand-in for walks (`Go/internal/emailmcp/walk`) | `Go/cmd/email-mcp/main.go`, `Go/internal/emailmcp` | a real mailbox, and the workflow run on a real sign-up code: Alex's test on #1780 |
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
| Google Cloud (Compute Engine VM and Cloud KMS) for the control plane | control plane | tested on a real account | 2026-10-18, `up.sh` made the VM `agents-control`, the live control plane moved there and back (`specs/058-control-plane/walks/1461.md`) | `deploy/gcp/up.sh`, `deploy/gcp/down.sh`, `deploy/gcp/startup.sh` | |
| Cloudflare DNS for the control plane's names | control plane | tested on a real account | 2026-10-18, `dns.sh` made the A records for control.agentloops.dev and views.agentloops.dev (`specs/058-control-plane/walks/1461.md`) | `deploy/cloudflare/dns.sh` | |

## Model gateways

Open issues: `is:open label:integration gateway`.

| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| Environment variables passed through (Bedrock, Vertex, base URL) | Mac, server | built | — | `Go/internal/agentsd/runtimes.go` | #999 |
| Org keys and gateways | — | planned | — | — | #999 |

## Planned (no code)

Open issues: `is:open label:integration`.

| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| Forgejo | — | planned | — | — | #813 |
| Google and Apple sign-in | — | planned | — | — | #995 |
| Enterprise OIDC and SCIM | — | planned | — | — | #1002 |
| Google Chat | — | planned (parked) | — | — | #1016 |

## Removed

| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| Slack and the Channels layer | — | removed | 2026-10-16, PR #1230 | — | #1223, closed |
