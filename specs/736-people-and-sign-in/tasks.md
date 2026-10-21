# Tasks: Team tier: people, machines and sign-in

**Input**: `spec.md`, `plan.md`, `research.md`, `data-model.md`, `contracts/control-api.md` in `specs/736-people-and-sign-in/`.

**Tests**: the spec asks for automated checks (SC-003, SC-005, SC-007, SC-008), so each story has test tasks. Write them first.

**Format**: `[ID] [P?] [Story] Description`. `[P]` means a task can run in parallel with the others of its phase (different files).

**Not before v0.7.0 ships.** Nothing here merges to `main` until then.

## Phase 1: Setup

- [ ] T001 Rename the `area:workspaces` label to `area:machines`, and map the paths in `.agents/areas`.
- [ ] T002 [P] Add `github.com/coreos/go-oidc/v3` to `Go/go.mod`. Check the licence and govulncheck with `scripts/lint.sh`.
- [ ] T003 [P] Add the app's Google, Apple and GitHub client ids as build settings (`App/`, `Remote/`) and as constants in `Go/internal/controlplane/people/`. Placeholders until Alex makes them (#995).

## Phase 2: Foundation (blocks every story)

- [ ] T004 Add the methods and notifications of `contracts/control-api.md` to `Packages/Wire/control.openrpc.json`, and the channel-0 messages to `daemon.schema.json`. Run `scripts/wire.sh gen`, and commit `Go/wire/*_gen.go` and `Web/src/protocol/generated.ts`.
- [ ] T005 Extend `records.Person` to User (`kind`, `role`, `signIns`, `group`, `caps`, tombstone), and add `signins/` uniqueness keys, in `Go/internal/controlplane/records/types.go` and `records.go`.
- [ ] T006 [P] Add the records Invite, Group, JoinRequest, ChannelLink, RunClaim and Spend in `Go/internal/controlplane/records/`.
- [ ] T007 Write the migration on first start: the existing person becomes the local owner and admin, gets `{local, <control-key id>}`, and every client, host and provider record gets that person as `owner` (FR-003). It only adds fields. Test it on a copy of a v0.7 store in `records_test.go`.
- [ ] T008 Add the in-memory owner index (host → user, client → person), refreshed on record change, in `Go/internal/controlplane/router.go`.
- [ ] T009 Add the owner check for every client method in `router.go` and `methods.go`. Another user's machine is `notFound`. Admins get name, user and state only.
- [x] T010 Write a table test over **every** client method in `Go/internal/controlplane/security_test.go`: 10 users and 30 hosts, and no request reaches a host that is not the caller's (SC-003). A new method with no entry fails the test.
- [x] T011 Refuse older builds on a control plane with more than one person with `updateToJoinTeam` (R14), in `conn.go`.

**Checkpoint**: one person sees no change, and the owner check is in force.

## Phase 3: US1, one person sees no change (P1)

- [ ] T012 [US1] Test that a code-paired client and a code-enrolled host belong to the local owner, in `Go/internal/controlplane/service_test.go`.
- [ ] T013 [P] [US1] Mac: the Settings rail grouped by This device / You / Control plane, in `App/Sources/Settings/SettingsWindow.swift`. Move each pane to its group. Machines holds today's Control plane ▸ Hosts and the Mac pane.
- [ ] T014 [P] [US1] Remote: the same three sections, in `Remote/Sources/Panes/`.
- [ ] T015 [P] [US1] Web: the same three groups, in `Web/src/views/`.
- [ ] T016 [US1] Say "Machine" for host and workspace on all three clients, and show one Machines list (US3-7). Change the sidebar heading, the menus and Settings strings.

## Phase 4: US2, a second person joins by signing in (P1)

- [ ] T017 [US2] Write tests first: an OIDC check against a local JWKS server (signature, `iss`, `aud`, expiry, nonce, 5 min skew, key rotation), a replay to a second control plane, and an invite that is used or has expired, in `Go/internal/controlplane/people/oidc_test.go`.
- [ ] T018 [US2] Add `people/oidc.go`: `signIn/providers`, `signIn/oidc`, `signIn/addToMe` (FR-005, FR-008, FR-009, FR-011, FR-015).
- [ ] T019 [US2] Add `people/github.go`: `signIn/github` with `GET /user` (and the membership check for allowed organisations), forgetting the token. Invite only, and later clients wait for approval (FR-010). Test with an `httptest` GitHub.
- [ ] T020 [US2] Add `people/invites.go`: `people/invite` and redemption (7 days, one use, the Google email must match), plus allowed domains and organisations (FR-006, FR-007). Add `signIn/configure`.
- [ ] T021 [P] [US2] Mac: a sign-in sheet (Apple, Google, GitHub device flow, Use a Code) in `App/Sources/Control/ConnectSheet.swift`, and **Add a Sign-in** under You ▸ Account.
- [ ] T022 [P] [US2] Remote: the same sign-in sheet, in `Remote/Sources/Link/`.
- [ ] T023 [P] [US2] Web: pair by a code from a signed-in client, as today. **Add a Browser** belongs to the person (FR-014), in `Web/src/views/Pairing.tsx`.
- [ ] T024 [US2] The GitHub client approval card on a person's signed-in clients, in `Shared/UI/` and `Web/src/views/Approval.tsx`.

## Phase 5: US3, a machine joins its user (P1)

- [ ] T025 [US3] Write tests first: a join request (code, 10 min expiry, approve, deny, rate limits), a machine code owned by its maker, and a one-use join token, in `Go/internal/controlplane/joins/joins_test.go`.
- [ ] T026 [US3] Add `joins/`: `hosts/requestJoin`, `hosts/approveJoin`, `hosts/denyJoin`, and `control/joinRequested` to the person's or admins' clients (FR-017, R5).
- [ ] T027 [US3] `agentsd` asks to join when it has no code: it prints the code and waits, in `Go/internal/controllink/` and `Go/cmd/agentsd/`. The one-line install command gains `--person`.
- [ ] T028 [US3] Workspace providers get a join token for each start and pass `AGENTS_JOIN_TOKEN`, in `Go/internal/controlplane/providers/` and `workspaces.go`. The started machine belongs to the starter.
- [x] T029 [US3] The direct path (#1118) only when the window's person owns this Mac's machine (FR-020). `signInFrom` and `gitFrom` only within one user (FR-021).
- [ ] T030 [P] [US3] The machine approval card on all three clients, in `Shared/UI/ApprovalViews.swift` and `Web/src/views/Approval.tsx`.

**Checkpoint**: T1 and T2 can be used by two people. Walk `quickstart.md` steps 1–3.

## Phase 6: US4, settings follow you (P2)

- [x] T031 [US4] Write tests first: an envelope round trip with the local keeper, no readable secret under the prefix (SC-007), and a secret sent only on its user's machines' links, in `Go/internal/controlplane/usersettings/usersettings_test.go`.
- [x] T032 [US4] Add `usersettings/`: `user/settings`, `user/setSettings`, `user/setSecret`, `user/removeSecret` and `user/secretNames` over `kms.Keeper` (FR-024, FR-025).
- [ ] T033 [US4] Send `user/settings` at join and on change over channel 0 (`Go/internal/controllink/`). `agentsd` writes the items into `~/.agents` and `~/.agents-secrets`, marks them as from the control plane, and refuses local edits to them.
- [x] T034 [US4] When a machine is removed: stop sending secrets to it, and tell the user which secrets it had (FR-026).
- [ ] T035 [P] [US4] Move MCP servers, Agent Configuration, runtime choices, Cost and Resources under You on all three clients. Each pane reads and writes the user scope.

## Phase 7: US5, admins manage people, groups and providers (P2)

- [ ] T036 [US5] `people/list`, `people/setRole` (refused if it leaves no admin, with `matching`), `people/removePreview` (asks each started machine for unpushed work) and `people/remove` (FR-029). Test that a removal is in force on two copies within 5 s.
- [ ] T037 [US5] Add `groups/*` and `providers/setGroup`. Only a group's users see and start its providers (FR-027, FR-028).
- [ ] T038 [P] [US5] Control plane ▸ People, Groups and Workspace Providers panes on all three clients. Members see themselves and Overview, read only.

## Phase 8: US6, bots (P2)

- [ ] T039 [US6] Write tests first: a bot's machine refuses client actions (`botMachine`), there is no Run now, one trigger with three machines gives one run in 100 tries (SC-008), and a cap stops the bot.
- [ ] T040 [US6] Add `bots/make`, `bots/setCaps` and `bots/stopRun`. Admins approve a bot's machines (FR-030, FR-031).
- [ ] T041 [US6] `agentsd`: no ask tools when `userKind` is bot. Permissions come from policy alone, and a blocked run ends as `needsAttention` with a notice to admins (FR-032). Files: `elicitations.go`, `apptools.go`.
- [ ] T042 [US6] `runs-on:` replaces `hosts:` in `workflowfile.go`, with machine labels. Add `workflows/claimRun` with a create-only `runs/<workflow>/<trigger>.json`. With no bot machine online, the control plane starts one (#1004) (FR-034).
- [ ] T043 [US6] Scoped events: machine events stay on the machine. Project and control-plane events are sent once by the control plane (FR-035).
- [ ] T044 [US6] Spend: machines send `cost/report`. The control plane adds it up per bot and per group, and sends `user/capReached` (FR-033).
- [ ] T045 [P] [US6] Bots in People, and **Needs attention** for a bot's run, on all three clients.

## Phase 9: US7, channels (P2)

- [ ] T046 [US7] Add `links/*` and `control/linkRequested`. A message from an identity that is not linked starts nothing. Email checks DKIM (FR-036, FR-037).
- [ ] T047 [P] [US7] The link approval card on all three clients, and Control plane ▸ Channels.

## Phase 10: US8, who did what (P3, T3)

- [ ] T048 [US8] The router stamps `actor` on every event and on every passed call's envelope. `agentsd` writes it into `events.jsonl`. A client's own `actor` field is ignored (FR-039).
- [ ] T049 [US8] `audit/list`, `audit/export` and `control/setAuditDays` (default 90), and the sweep (FR-040).
- [ ] T050 [P] [US8] Activity ▸ Audit on all three clients (FR-041).

## Phase 11: US9, key lifetimes (P3, T4)

- [ ] T051 [US9] `expires` on client and host records, and renewal over R6. An outside sign-in must still be valid (FR-042).
- [ ] T052 [US9] `control/rotate` and `control/newKey`. Clients and machines keep both keys for one release (FR-043). Rewrite spec 058 FR-013 to point here.

## Phase 12: Polish

- [ ] T053 [P] Write the docs in the spec's Docs section.
- [ ] T054 [P] Add rows to `specs/071-web-remote/walks/parity.md` for each item in FR-044.
- [ ] T055 [P] Add the Google, Apple and GitHub sign-in rows to `docs/reference/integrations.md`.
- [ ] T056 Walk `quickstart.md` end to end on a scratch set-up. Record the walk under `specs/736-people-and-sign-in/walks/`.

## Dependencies

- Phase 2 blocks everything.
- US1, US2 and US3 ship together (T1 and T2 together).
- US4 needs US3 (machines with users).
- US5 needs US2 and US3.
- US6 needs US4 and US5 (groups).
- US7 needs US2.
- US8 needs Phase 2, and is best after US6, so that bot actors exist.
- US9 needs US2.
- Client tasks marked [P] in one phase can run beside each other, each after its phase's Go tasks.
