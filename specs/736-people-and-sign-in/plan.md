# Implementation Plan: Team tier: people, machines and sign-in

**Branch**: `agents/work-github-issue-1117` (spec only) | **Date**: 2026-10-20 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/736-people-and-sign-in/spec.md` (#1117, covering #994–#997).

## Summary

The control plane gets users (people and bots), each with a role. Every client belongs to a person, and every machine (host or workspace) to one user.

- **People sign in** with Google or Apple (an ID token with a nonce bound to the control plane), with GitHub (by invite, and later clients by approval), or as the local owner (codes).
- **Machines join** by approval on a signed-in client, by a machine code, or by a join token from a workspace provider.
- **Settings** get the scopes this device, you and control plane. The control plane keeps user settings, and user secrets in envelope encryption with Google Cloud KMS or a local key file, and sends them to the user's machines.
- **Groups** own workspace providers and bot cost.
- **Bots** run team workflows chosen by `runs-on:`, once per trigger, with a run claim in the store.
- **T3:** the router stamps an actor on every action.
- **T4:** keys expire and renew, and the control key rotates.

## Technical Context

**Language/Version**: Go 1.24 (`Go/`: `agents-control`, `agentsd`). Swift 6 (the Mac window, the Remote, `Shared/UI`, `Packages/AgentsKit`). TypeScript (the web page, `Web/src`).

**Primary Dependencies**:

- `github.com/coreos/go-oidc/v3` (JWKS and ID-token checks);
- the existing `kms` keeper (Google Cloud KMS, local file);
- AuthenticationServices on Apple platforms (`ASAuthorizationAppleIDProvider`, `ASWebAuthenticationSession`);
- the GitHub device-flow endpoints, over HTTPS.

No new database.

**Storage**: the control plane's store (folder or S3), plain JSON under `<prefix>/v1/` (`data-model.md`). On machines: `~/.agents` and `~/.agents-secrets`, as today.

**Testing**:

- `Go/scripts/go.sh test ./...`: the router owner check for every client method, migration, sign-in checks with test JWKS, join requests, run claims, and the envelope.
- `swift test` for the AgentsKit models.
- Biome and Vitest for the web.
- Walks with `run-app` and `test-servers` on a scratch control plane with two people.

**Target Platform**: macOS 27, iOS and iPadOS 27, Linux (machines and the control plane), current browsers.

**Project Type**: a distributed app: control plane, machines, and three clients.

**Performance Goals**:

- An owner check adds under 1 ms per routed call (an in-memory index of host → owner, refreshed on change).
- A removal is in force on every copy within 5 s.
- Secrets are on a new machine within 30 s of its join.

**Constraints**:

- No cloud login is ever required (the local owner).
- Plain files only.
- No readable secret in the store.
- Only fields are added to existing records.
- v0.x takes breaking changes: `hosts:` stops working, with no migration code.

**Scale/Scope**: about 20 people, 10 bots and 50 machines per control plane.

## Constitution Check

| Principle | How this plan meets it |
|---|---|
| I. Spec-led | Spec, clarifications, this plan and `tasks.md` come before any code. The build waits for v0.7.0 to ship. |
| II. Capability-driven runtimes | Bots drop the ask tools by the machine's user kind, not by runtime. Runtime sign-ins stay the runtime's own. |
| III. Scoped access and user control | The router refuses another user's machine. Agent tools see only their user's sessions. Bots ask nobody, and their policy and caps decide instead. Approvals (machines, channel links, GitHub clients) reach the person on app-owned cards. |
| IV. Work must be inspectable | T3 records the actor on every action. A bot's run that cannot go on ends as **Needs attention** with a notice. |
| V. Docs and quality travel with the feature | The spec's Docs section lists every page. Each task phase ends with its docs and parity rows. Generated wire files come from `Packages/Wire`. |

There is no violation, so Complexity Tracking is empty.

## Project Structure

### Documentation (this feature)

```text
specs/736-people-and-sign-in/
├── spec.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/control-api.md
├── checklists/requirements.md
└── tasks.md
```

### Source Code (repository root)

```text
Packages/Wire/                         control.openrpc.json, daemon.schema.json (wire first, #1135)
Go/internal/controlplane/
├── records/                           User, SignIn, Invite, Group, JoinRequest, settings, secrets, links, runs
├── people/        (new)               sign-in checks (oidc, github, local), invites, roles, removal
├── joins/         (new)               approve-to-join, join tokens
├── usersettings/  (new)               user settings, envelope secrets over kms
├── router.go, rpc.go, methods.go      owner check, actor stamp, bot refusal
├── providers/                         group on each provider, join token on start
├── kms/                               the keeper (exists)
└── web/                               the page's code pairing, as today
Go/internal/controllink/               host/hello reply (user, kind, labels), user/settings, claimRun, renew
Go/internal/agentsd/
├── workflowfile.go, workflows*.go     runs-on:, claimRun, scoped events
├── agenttools.go, apptools.go         sessions of the machine's user only
├── elicitations.go                    no ask tools for a bot
└── (settings writers)                 kept items marked as from the control plane
App/Sources/Settings/, App/Sources/Control/   rail by scope, People, Groups, sign-in, approval card
Remote/Sources/Panes/, Remote/Sources/Link/   the same on the Remote
Shared/UI/                             approval card, Machines list, Needs attention
Web/src/views/                         the same on the web, code pairing
docs/                                  the pages in the spec's Docs section
```

**Structure Decision**: no new binary. The control plane gains three internal packages. Everything else extends what is there.

## Phases

1. **Foundation**: the wire, the records, the migration, and the owner check in the router. Without these, nothing is safe for a second person.
2. **Sign-in and joins** (US1–US3, P1). Then T1 and T2 are usable together.
3. **Scopes and secrets** (US4).
4. **Admin** (US5).
5. **Bots, workflows and channels** (US6, US7).
6. **Audit** (US8, T3).
7. **Key lifetimes** (US9, T4).
8. **Polish**: docs, parity, integrations rows, the area label.

Each phase is one lane or more, split by directory as `.agents/areas` says. Each lane verifies only what it touched. The Go control-plane work goes first, the clients after it, one PR per client or one for all three.

## Complexity Tracking

None.
