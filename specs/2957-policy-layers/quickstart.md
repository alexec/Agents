# Quickstart: prove the policy layers work

How to see each user story working, slice by slice. Use only scratch data: the repo is public. Hold the `build` lease only while a build, a test or a scratch app runs. Close every scratch app with the run-app skill's "When you are done" steps.

## Before you start

- A worktree of the slice's branch, and `scripts/build-cache.sh` for every build and test.
- For US2 and US6: a scratch control plane (the run-app skill sets one up) and the devbox (`test-servers` skill, `agents-devbox` on 127.0.0.1:2222).
- Contracts: [contracts/policy-layers-api.md](contracts/policy-layers-api.md). Types: [data-model.md](data-model.md).

## Slice 1: rules and resolver

```sh
scripts/build-cache.sh Go/scripts/go.sh test ./internal/policylayers/...
```

Expected: the table test passes for every rule × every pair of layers × tightest in each layer (SC-003: 0 escapes); `Looser` is true only for a looser rule; an unknown field is ignored; a 17 KiB layer is refused.

## Slice 2: your layer on one machine (US1, US5)

1. On a scratch root with no control plane, write the old files: `limits.json` (`daily` $40), `workflow-limit.json` (`total` 7), `display.json` (`noticeBurst` 2, `agentsMayArchiveMyChats` false) and `runtime-environment.json` (`names: ["FOO"]`).
2. Start the scratch app. Expected: `policy/yours` has those four values (SC-001); the old files are renamed `.moved`.
3. Call `policy/setYours` from the agent socket role (an `agentsctl` call as an agent). Expected: refused `forbidden` (SC-004).
4. Set `permissionMode: ask`, start an agent and ask it for Approve for me. Expected: `policyRefused` with `layer.kind: you`, rule `permissionMode`.
5. Make each rule of FR-007 stop an agent once. Expected: each refusal names rule and layer.

```sh
scripts/build-cache.sh Go/scripts/go.sh test ./internal/agentsd/... ./internal/controllink/...
```

## Slice 3: folder layer and other machines (US3, US6)

1. Write `.agents/policy.json` `{"permissionMode":"ask"}` in a scratch folder by hand. Expected: applies at once; event `policy.folderTightened`; agents in other folders are not changed.
2. Change it to `{}` by hand. Expected: pending; Ask still applies; `folders/keepGuardedChange` makes it apply; `folders/undoGuardedChange` writes back the old file.
3. Join the devbox to the scratch control plane with a join code from the scratch window. Set `budgets.perAgent` $5 on the Mac. Expected: the devbox applies it within 5 s (SC-005).
4. Edit the devbox's `policy-yours.json` by hand. Expected: the devbox keeps its last good copy and logs the failed check once.
5. Stop the devbox's link, change your layer, start the link. Expected: the devbox gets the newest copy.
6. With no control plane, add the devbox as a server from the window. Expected: `policy/applyYours` pins the key and applies the layer.

## Slices 4 to 6: the clients (US1 to US5)

With the run-app skill, Mac and headless Chrome; the walk simulator for the Remote. One screenshot per state and per client, for the PR (`pr-shots.sh`):

| State | Frame | Clients | Expected |
|---|---|---|---|
| Agents ▸ Policy, alone | C | Mac, web, Remote | "You set every limit"; no lock; values from slice 2 |
| Agents ▸ Policy, organisation caps the mode | A | Mac, web, Remote | 🔒 "Acme: at most Approve for me"; Bypass Permissions dimmed with the reason |
| Your value above the cap | A | Mac, web | "Kept, not used"; it applies again when the scratch organisation removes the rule |
| Where this comes from | B | Mac, web, Remote | layers from the top down; the deciding layer lit |
| Folder ▸ Policy | D | Mac (Folder Settings), web (Agents ▸ Policy ▸ folders) | "Same as yours"; values looser than yours dimmed |
| A looser change waits | D | Mac, web, Remote | card with Allow, Keep Ask, Show Change |
| Stopped by a policy | E | Mac, web, Remote | rule, layer, value; Change only for You and a folder |
| Old panes | F | Mac, web, Remote | This app ▸ Notifications gone; Sidebar without the switch; Control plane ▸ Organisation Policy |
| Remote edits | – | Remote | the notice burst, the wait and the archive switch save; other rows read only |

Also: `swift test` (filtered by `scripts/select-test-suites.sh`), `WireSchemaTests`, and `Web/test/policyLayers.test.mjs`, under the `build` lease.
