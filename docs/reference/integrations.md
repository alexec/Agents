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
The weekly runtime check writes the rows between the `runtimes` markers below; edit all other
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
| Copilot | Mac, Remote, web, server | broken (fails at turn) | 2026-10-17, 1.0.93-1: failed at turn, in `.agents/reviews/runtimes/copilot-2026-10-17.md` | `RuntimeCatalog.swift`, `runtimes.go` | |
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
| Docker | Mac, Remote, web, control plane | walked on scratch | 2026-10-13, PR #966 (`specs/691-workspace-providers/walks/857-real-providers.md`) | `presets.go` (`docker`) | #857, #1119 |
| Coder | Mac, Remote, web, control plane | built | — | `presets.go` (`coder`) | #1119 |
| Codespaces | Mac, Remote, web, control plane | broken (Stop works, Start never brings the host back) | 2026-10-13, PR #966, with a real codespace | `presets.go` (`codespaces`) | #864, #1119 |
| DigitalOcean | Mac, Remote, web, control plane | built | — | `presets.go` (`doctl`) | #865, #1119 |
| Google Cloud Workstations | Mac, Remote, web, control plane | built | — | `presets.go` (`gcloud-workstations`) | #1119 |
| Any MCP or CLI provider (map written by an agent) | Mac, control plane | built | — | `Go/internal/controlplane/providers/drafts.go` | |
| The misbehaving fake provider | control plane | walked on scratch | 2026-10-13, PR #862 | its tests | #857 |

## MCP and GitHub

Open issues: `is:open label:integration MCP`.

| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| The github server (official github-mcp-server tools plus our events) | agents | built | 2026-10-16, side by side with the ci server it replaced (#1231) | `Go/cmd/github-mcp/main.go`, `Go/internal/githubmcp` | the ci server's views (board, issues, PR page) are not back |
| MCP OAuth | Mac | built | — | `Go/internal/agentsd/mcpcatalog/oauth.go`, `App/Sources/Catalog/MCPSignInSheet.swift` | |
| Events from MCP servers (polling only) | Mac, Remote, web | built | — | `Go/internal/agentsd/mcpevents.go` | |
| Git credentials lent from the Mac to a Linux host | Mac, server | built | — | `App/Sources/Hosts/Lending.swift` | |

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
| CloudKit relay channel (Remote to Mac) | Remote, Mac | built | — | `Packages/AgentsKit/Sources/AgentsKit/Relay/ControlRelay.swift`, `Host/Relay/Sources/main.swift` | |
| Local notifications | Mac, Remote | built | — | `App/Sources/Notifications/MacNotifier.swift`, `Remote/Sources/Notifications/DeviceNotifier.swift` | |
| The attention widget | Remote | built | — | `RemoteWidget/Sources/AttentionWidget.swift` | |

## Control plane hosting

Open issues: `is:open label:integration "control plane"`.

| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| S3 or MinIO store | control plane, Mac | built | — | `Go/internal/controlplane/s3store/s3store.go`, `Host/Sources/StoreChoice.swift` | |
| KMS (local, HashiCorp Vault, Google Cloud KMS) | control plane | built | — | `Go/internal/controlplane/kms/kms.go` | |
| Caddy with ACME | control plane | built | — | `deploy/` | #61 |
| Bonjour discovery | Mac, control plane | built | — | `Host/Sources/LocalServices.swift`, `Go/internal/controlplane/machine.go` | |
| ssh host install and tunnels | Mac, server, control plane | built | — | `Go/internal/controlplane/hostinstall/ssh.go`, `Go/internal/controlplane/hosttunnels/ssh.go` | |
| The control plane on a cloud machine | control plane | planned | — | — | #61 |

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
| Linear | — | planned | — | — | #839 |
| GitLab or Forgejo | — | planned | — | — | #813 |
| Google and Apple sign-in | — | planned | — | — | #995 |
| Enterprise OIDC and SCIM | — | planned | — | — | #1002 |
| Google Chat | — | planned (parked) | — | — | #1016 |

## Removed

| Integration | Clients that show it | State | Last checked | Where | Gaps |
| --- | --- | --- | --- | --- | --- |
| Slack and the Channels layer | — | removed | 2026-10-16, PR #1230 | — | #1223, closed |
