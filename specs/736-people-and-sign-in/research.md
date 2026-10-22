# Research: Team tier: people, machines and sign-in

Phase 0 for `plan.md`. Each entry gives a decision, why, and what was rejected.

## R1. Where the code is today

- **The control plane and `agentsd` are in Go** (`Go/internal/controlplane`, `Go/internal/agentsd`). The Swift ones were removed in #1314.
- **`records.Person`** (`Go/internal/controlplane/records/types.go`) has only `id` and `name`. `ClientRecord`, `HostRecord` and `Settings` already carry `owner`, but nothing reads it. T1 makes `owner` real, and changes no key.
- **`HostRecord.Workspace`** links a host to the workspace it runs on (#691). A "machine" is a `HostRecord`, with or without `Workspace`. The store needs no new record kind for it.
- **Workspace providers** are in `Go/internal/controlplane/providers`. Their secrets are in the control plane's own folder, not in the store.
- **`Go/internal/controlplane/kms`** is the key keeper from #1126 and #61: Google Cloud KMS, and a local 0600 file.
- **Workflows** read `hosts:` in `Go/internal/agentsd/workflowfile.go`.
- **The agent tools** are in `Go/internal/agentsd/agenttools.go` and `apptools.go`, and the ask tools in `elicitations.go`.
- **The wire** comes from `Packages/Wire` (`control.openrpc.json`, `daemon.schema.json`), made by `scripts/wire.sh gen` (#1135).

## R2. Google and Apple sign-in

- **Decision**: as in the 2026-10-11 roadmap (T2).
  - The client signs in.
  - The control plane checks the ID token against JWKS, `iss`, `aud`, the expiry, and `nonce = SHA-256(controlKeyID ‖ helloNonce)`.
  - In Go: `github.com/coreos/go-oidc/v3` for discovery, the JWKS cache and the checks.
- **Why**: the audience is the app's own client ids, so no operator registers anything (FR-012). The nonce makes a token good for one control plane and one connection (FR-011).
- **Rejected**: the control plane runs the OAuth redirect itself. It would need a redirect URI for each self-hosted domain, so each operator would need a registration.

## R3. GitHub sign-in and replay

- **Decision**:
  - The client uses a **GitHub App** with the **device flow**, and user tokens that **expire** after 8 hours.
  - It asks for no scope, or `read:org` when an organisation is allowed.
  - The control plane calls `GET /user` once (and `GET /user/memberships/orgs/<org>` when an organisation is allowed), keeps `(github, id)` and `login`, and forgets the token.
  - A GitHub person **joins only by an invite**, and **each later client needs an approval** on a signed-in client of that person.
- **Why**: a GitHub token cannot carry a nonce. A control plane that gets one could send it to another control plane that trusts the same App, for as long as the token is valid. An invite or an approval belongs to one control plane, so a replayed token alone pairs nothing (FR-011, SC-005). Tokens that expire limit the time a stolen token is good for.
- **Rejected**:
  - **The control plane revokes the token after the check.** That needs the App's client secret on every control plane, which breaks FR-012.
  - **Accept the risk for a token with no scope.** A replay would let a hostile control plane sign in as the person on another control plane. That is the attack that matters.
  - **Allowed organisations let a person join with no invite.** That is the replay case again: membership of an organisation does not bind the token to this control plane.

## R4. The local owner provider

- **Decision**:
  - The sign-in `(local, <control-key id>)`.
  - Pairing codes and machine codes are its sign-in: a code proves "the same person as the client that made the code".
  - The local owner is a person. That person can add outside sign-ins to themselves.
  - Whoever holds the control plane's key (Agents Host, or `agents-control admin`) can make a person admin. That is how the last admin is recovered.
- **Why**: Alex chose one identity model, 2026-10-18 (#995). Nobody is forced to have a cloud login, and the code has no "no person" case.

## R5. Approve-to-join for machines

- **Decision**:
  - A machine that has no code makes a key pair and calls `hosts/requestJoin {name, publicKey, platform, person?}` on an unauthenticated enrolment connection.
  - The control plane keeps a **join request** (`joins/<id>.json`) with a 6-character code, for 10 minutes.
  - It sends `control/joinRequested` to every client of the named person (or of every admin, for no person or for a bot).
  - **Approve** (`hosts/approveJoin`) binds the machine's key to that user. The waiting machine's connection then gets `{host}`, as `hosts/announce` gives today.
- **Why**: it is the pattern of `tailscale up` and `gh auth login`. Nothing secret is typed on the machine, and the person sees the same code on both screens, which stops a request being approved for the wrong machine.
- **Rate limit**: 10 open requests per control plane, and 3 per source address. Above that, a request is refused, so a stranger cannot flood people with cards.
- **Join tokens for started machines**:
  - `providers` asks the control plane for a token, for one use and one user, valid for 1 hour.
  - The token is passed in the start's environment (`AGENTS_JOIN_TOKEN`) beside the address and the pin.
  - The machine spends it as it spends a machine code today (`codes/<id>.spent`).

## R6. User settings and secrets

- **Decision**:
  - User settings are kept at `users/<id>/settings.json`.
  - Secrets are kept at `users/<id>/secrets/<name>.json` as `{dataKeyWrapped, nonce, ciphertext, keyVersion}`: AES-256-GCM, with the data key wrapped by `kms.Keeper`.
  - A machine gets its user's settings and unwrapped secrets on channel 0, in `user/settings` (at join, and on change), over the R6 link that is already encrypted end to end.
  - `agentsd` writes them where they are kept today: `~/.agents` for settings, and `~/.agents-secrets` for secrets. Each kept item is marked as from the control plane, so a local edit is refused with "set under You".
- **Why**:
  - Alex decided that the control plane holds secrets "securely", in Google Cloud KMS.
  - The store holds no readable secret (rule 7).
  - A started machine gets its secrets with nobody online (SC-006).
- **Rejected**: sealing each secret to each machine's key. A machine started tomorrow has no key yet, so a person would have to be online to seal for it.

## R7. Which settings move to the user scope

- **Decision**: these move to the user:
  - MCP servers and their secrets;
  - agent configuration (shared skills, instructions, personas);
  - runtime choices and models;
  - cost limits;
  - resources limits.

  Runtime sign-ins stay on each machine, because they are the runtime's own files, made by its own login. Machine settings (disk, keep awake, relay) stay on the machine. Project settings stay with the project.
- **Why**: a started machine must work as its user's machine at once. A runtime's sign-in cannot be copied safely between machines. #1122's lending (`signInFrom`, `gitFrom`) already covers that, now limited to the same user.

## R8. Settings window by scope

- **Decision**: as decided on #1117. There is one window, and the rail has three groups. On the Remote, they are three sections in Settings. On the web, three groups in its settings column.
- **Members**: they see Control plane ▸ People (themselves) and Overview, read only. Admins see every pane.

## R9. Bots

- **Decision**:
  - `users/<id>.json` with `kind: "bot"`, a `group`, and `caps`.
  - Its machines join by admin approval.
  - The control plane refuses every agent-starting and answering method from a client for a bot's machine (FR-031). The router checks it, so no client can get around it.
  - `agentsd` drops the ask tools from a session when its machine's user is a bot. The control plane says this in `host/hello`'s answer, as `userKind`.
  - A permission prompt is answered by policy. A blocked run ends as `needsAttention`.
- **Spend caps**:
  - Each bot machine reports its cost (already counted in `cost.go`) to the control plane in its idle reports.
  - The control plane adds it up per bot and per group per day, and sends `user/capReached` to the bot's machines, which stop starting runs.

## R10. Workflows: `runs-on:` and run leases

- **Decision**:
  - **Machine labels** are `os:<darwin|linux>`, `provider:<name>`, the user's or bot's name, and the machine id.
  - `runs-on:` is a list of labels. All must match, except machine ids: a machine has one, so it runs when its id is one of them (#2064).
  - **A trigger for a bot's workflow:** each of the bot's machines that sees it asks `workflows/claimRun {workflow, triggerID}`. The control plane writes `runs/<workflow>/<triggerID>.json` with `absent`, and the first machine wins (the store's create-only condition). The others are told `taken`.
  - **Schedules and project events** for bots come from the control plane (scoped events, FR-035). So with no bot machine online, the control plane starts one (#1004 wake-up) and keeps the trigger.
  - **Personal workflows** (no `runs-on:`) run on each machine of each user who turned them on, as today.
- **Why**: the store's conditional create is the one lock that works across copies (contract `store.md`, rule 1).

## R11. Channel identities

- **Decision**:
  - `links/<channel>/<identity-hash>.json` → `{user, approvedBy, approvedAt}`.
  - A message from an identity with no link sends `control/linkRequested` to the person the identity claims, when it can be told: a Slack user's email matched to a person's sign-in email for display only, else to every admin. The message starts nothing.
  - For email, the channel's MCP server reports `dkim: pass|fail` for the `From:` domain. `fail` is refused.

## R12. Audit (T3)

- **Decision**:
  - The control-plane events (`events/<day>/<ulid>.json`) get `actor: {user, client?, event?}`. The router writes it from the connection, never from the request.
  - Retention defaults to 90 days. `control.json` has `auditDays`.
  - Calls passed to a machine carry `actor` in the channel envelope. `agentsd` writes it into `events.jsonl`.
  - `audit/list {since, until, user?}` and `audit/export` stream JSON lines.

## R13. Key lifetimes (T4)

- **Decision**:
  - Client and machine records get `expires` (90 days from pairing or renewal).
  - A connection in the last 30 days of its key's life gets `control/renew`. The client signs the new expiry with its key, and the control plane writes it.
  - An outside sign-in client must show a fresh ID token, or for GitHub a token that `GET /user` accepts, at renewal.
  - Control-key rotation: `control/rotate` sends `{newKey, signature-by-old}`. Clients and machines keep both keys until the old one is gone (one release).

## R14. Older builds

- **Decision**: on a control plane with one person, a client or machine that sends no person is read as the local owner's, as today. When a second person joins, the control plane refuses older builds with "Update Agents to join this team". v0.x takes breaking changes, so there is no other path for older builds.

## R15. Order of building

- **Decision**:
  1. **Foundation:** records, migration, the router check.
  2. **Story 1, Story 2 and Story 3 together:** T1 and T2 cannot be shipped apart.
  3. **Story 4** (scopes and secrets).
  4. **Story 5** (admin panes, groups, removal).
  5. **Story 6 and Story 7** (bots, channels).
  6. **Story 8** (T3), then **Story 9** (T4).
- **Areas**:
  - Control-plane work is `area:control-plane`.
  - Workflow and agent-tool work in `agentsd` is `area:agent-tools`.
  - Settings UI is per client.
  - `area:workspaces` becomes `area:machines`.
