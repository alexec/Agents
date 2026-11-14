# Data inventory: what Agents stores, where, and how it is bounded

Status: research, 2026-11-06, by the Product Owner. Read from the code on `main` at e0a74e17f.
Nothing was run. Every bound below has its constant and `file:line`, so a lane can check it.

This inventory includes and replaces the store lists in
`docs/explanation/compliance/data-and-retention.md` and `docs/reference/agents-folder.md`.
Those pages leave out many stores and get some bounds wrong (see "Where the docs are wrong",
at the end).

**Kinds of bound** used in the tables:

- **time**: data older than a limit is deleted.
- **count**: only the newest N are kept.
- **size**: a byte limit.
- **life**: the data goes when its owner (an agent, a person, a machine) goes.
- **none**: nothing removes it.

**Swept** says when the bound is applied: on write, on read, hourly, or at start. A bound that
is applied only on read or only at start is a weak bound.

Paths in the first three sections are relative to `Go/internal/` unless shown otherwise.

## Contents

1. [On each machine (agentsd)](#1-on-each-machine-agentsd)
2. [In each folder (`<folder>/.agents/`)](#2-in-each-folder-folderagents)
3. [Outside our folders (runtimes, git, cloud)](#3-outside-our-folders)
4. [On the control plane](#4-on-the-control-plane)
5. [The hosted service](#5-the-hosted-service)
6. [Agents Host on the Mac](#6-agents-host-on-the-mac)
7. [The clients: Mac window, Remote, web page](#7-the-clients)
8. [In memory](#8-in-memory)
9. [Unbounded data, ranked](#9-unbounded-data-ranked)
10. [Where the docs are wrong](#10-where-the-docs-are-wrong)

---

## 1. On each machine (agentsd)

`<root>` is `~/Library/Application Support/Agents` on a Mac, `~/.local/share/Agents` on Linux,
and `~/.agents-server/root` on a joined server. `<cache>` is
`~/Library/Caches/com.alexecollins.agents` on a Mac. `<logs>` is `~/Library/Logs/Agents` on a Mac.
(`agentsd/store/locations*.go`)

Every `*.json` store is written atomically (`store.WriteAtomically`, `store/files.go:16`). A
store that cannot be read is set aside as `.unreadable-<t>` or `.corrupt-<t>`, and only the
newest 3 are kept (`SetAsidesKept`, `store/files.go:45`).

A machine backup holds only `agent.json`, `transcript.jsonl`, `turns.jsonl`, `app-tools.jsonl`
and `said.json` for each agent, and `usage-history.json`, `time-history.json` and `erased.json`
from the root (`agentsd/backups.go:69,72`). It holds nothing else.

### Agents and conversations

| Store | Holds | Bound | Swept | In backup |
|---|---|---|---|---|
| `agents/<ID>/agent.json` | The agent's record | **life.** An archived agent is deleted after 7/14/30/90 days or Forever, 30 by default (`retention.go:19-31,86`). A pinned agent is kept. | at start, then hourly (`retention.go:15,96-110`) | yes |
| `agents/<ID>/transcript.jsonl` | The whole conversation | **life, no size limit** | with the agent | yes |
| `agents/<ID>/app-tools.jsonl` | Each call to an app tool | Answers cut to 2,000 runes (`assess.go:35,145`). **Arguments are not cut**, and there is no line limit. | with the agent | yes |
| `agents/<ID>/said.json` | Search index of what was said | 32 KiB (`said.go:22`) | with the agent | yes |
| `<cache>/turns/<ID>.jsonl` | Turn summaries | life. Media base64 is limited (`turns.go:1197`). | with the agent (`store/store.go:217`) | **no** (the backup reads the wrong path, see section 10) |
| `erasures.json` | Runtime copies still to erase | 1,000 entries, 3 tries, 7 days (`erasure.go:40-45`) | on write | no |
| `erased.json` | Every agent deleted here | 10,000 IDs, 400 days | on write | yes |
| `elsewhere.json` | Sessions started on or from other machines | 200 per list (`elsewhere.go:40`) | on save | no |

### Events, usage, cost and lineage

| Store | Holds | Bound | Swept | In backup |
|---|---|---|---|---|
| `events.jsonl` | The machine's events | 7 days and 10,000 events, applied at 10,500 (`events.go:30-35,460`). Consequence lines have no count limit. | at load, hourly, on write | no |
| `events-state.json` | Branch tips, cost crossings, disk levels, wait restarts | Live folders only; today only; pruned | on write | no |
| `usage-history.json` | Usage | 168 hour **keys**, 90 day **keys** (`cost.go:29-30`) | on write | yes |
| `time-history.json` | Time, recaps, records | 168 hours / 90 days / 90 recaps (`timeledger.go:297`) | on write | yes |
| `spend.json` | Daily spend for cost limits | 7 **keys** (`cost.go:28`) | on write | no |
| `report-hours.json` | Hourly rollup for the control plane | 8 days (`reportledger.go:30`) | on save | no |
| `features-history.json` | Feature use counts | 90 day keys (`features.go:20`) | on write | no |
| `lineage.jsonl` | SDLC graph links | Ended links 90 days, 20,000 links, rewritten at +2,000 (`lineage/lineage.go:97-107`) | at open and on append growth; **no timer** | no |
| `lineage-cost.json` | Cost per node | 90 days, 5,000 nodes (`lineagecost.go:35,40`) | on save | no |
| `lineage-sync.json` | Links and session states unsent to the control plane (#4275) | 2,000 links, 5,000 states saved (25,000 held); past that it saves "send all again" instead (`lineagesync.go:31-40`) | on save | no |
| `ci-timings/sync.json` | Days of build timings unsent to the control plane, per repository (#5232) | 90 days of at most 20 repositories (`cisync.go`) | on send | no |
| `lineage-comments.json` | PR cost comments | 500, 30 days (`lineagecomment.go:42-44`) | on save | no |
| `release-tags.json` | Tags already linked, per repo | **none** (`lineagerelease.go:109`) | never | no |
| `achievements.json` | Milestones | fixed set | n/a | no |

### Workflows, assessments, approvals and devices

| Store | Holds | Bound | Swept | In backup |
|---|---|---|---|---|
| `workflows.json`: runs | Workflow runs | 7 days (`workflowruns.go:27`) | **at start only** (`workflowruns.go:1054`), and when a run ends | no |
| `workflows.json`: states | One state per (folder, workflow) ever seen | **none.** `GoneSince` (`workflows.go:59`) is declared and never set. | only the app's Remove | no |
| `workflow-copies/<sha256>` | Approved workflow and skill text | The copies that the states name (`workflows.go:244`) | after each save | no |
| `assessments/*.json` | Runtime assessments | newest 50 (`assess.go:208`) | on a new start | no |
| `mcp-events.json` | Seen MCP event IDs | 2,000 IDs, 7 days (`mcpevents.go:53-56`) | on write | no |
| `mcp-views/*.json` | View catalogues | pruned (`viewservers.go:369`) | on write | no |
| `mcp-approvals.json`, `plugin-approvals.json` | Approval digests | **none.** Grows with folders × servers. | MCP: only on explicit remove; plugins: never | no |
| `devices.json` | Paired devices | **none** | only Forget (`devices.go:257`) | no |
| `review-dismissals.json`, `review-opened.json` | PR URLs per folder | 200 per folder (`reviews.go:28,30`). **Folder keys are never pruned.** | on write | no |
| `lock-seen.json` | Signed request IDs | 4,096 (`lockcheck.go:42`) | on write | no |
| `attention.json` | Needs, deliveries | live needs only | on write | no |
| `leases.json`, `resources.json` | Resource leases | 240-minute lease cap; dropped on agent stop (`leases.go:28,383`) | on write | no |
| `guarded-files.json` | Guarded file states | folders that exist | on save | no |
| `org-routes/<id>.json`, `runtimes/org/…` | Org key routes, stand-in homes | 50 routes (`orgroutes.go:46`) | on delivery | no |
| `runtimes/accounts/<rt>/<id>/` | Homes of added runtime accounts, **with the runtime's own transcripts** | removed with the account (`accounts.go:343`) | on remove | no |
| `browser/profile/` | Chromium profile shared by every browser sign-in | **none** | never | no |
| Small fixed files (`folders.json`, `root-id.json`, `project-tools.json`, `wake.json`, `policy*.json`, `backup-settings.json`, `settings/*.json`, …) | Configuration | fixed shape | n/a | no |

### Transfers, backups and staging

| Store | Holds | Bound | Swept | In backup |
|---|---|---|---|---|
| `backups/<rootID>/*.tar.gz` | Machine backups | Keep 1–10, 3 by default (`backups.go:45-46`); `.tmp` after 24 h | after each backup. **Other machines' folders in a shared backup folder are never pruned.** | n/a |
| `backups-upload/`, `backups-download/` | Server backup staging | removed after use | on use | no |
| `.restore-*` | Restore staging | deferred `RemoveAll`. **A crash leaves it.** | never | no |
| `Outgoing/`, `Incoming/` | Export, send, import | 1 hour untouched (`send.go:25`) | **only on the next transfer, or at start** | no |
| `Clones/<id>` | Clone staging | removed after the clone | and at start (`folders.go:740`) | no |

### Caches and logs

| Store | Holds | Bound | Swept |
|---|---|---|---|
| `<logs>/daemon.log` (+ `.previous.log`) | Daemon log | 4 MiB + 1 older (`rolllog/rolllog.go:13`). Output written straight to the duplicated stderr (a panic) is not checked until the next write. | on write |
| `<logs>/mcp-logs/<name>-<hash>.log` | Hosted MCP stderr | 1 MiB + `.1`, 32 servers (`hostedmcp.go:57,824`). A single write over 1 MiB is written whole. | on open |
| `<cache>/tools/<runtime>/<id>` | Pinned runtime toolsets | only the current one (`install.go:543`) | at host start |
| `<cache>/browser/chromium`, `toolsets` | Playwright Chromium | old revisions are left to Playwright | on install |
| `<cache>/browser/output/<agent>` | Playwright output | removed when the session ends. **A crash leaves it.** | session end |
| `<cache>/catalog-staging/<id>` | Skill previews | 8, 30 minutes (`skillcatalog/preview.go:37-38`). The list is in memory only, so **folders left over at a restart are never swept**. | on Put/Get/Take |
| `<cache>/option-cache.json` | Runtime options | 50 (`options.go:44`) | on write |
| `~/Library/{Caches,Logs}/…/roots/<name>-<hash>` | Cache and logs for each non-default root | **none on count**; never removed when the root is deleted | never |

### `~/.agents` and `~/.agents-secrets`

| Store | Holds | Bound | Swept |
|---|---|---|---|
| `~/.agents/settings/*.json` | Settings that follow the person (see `docs/reference/agents-folder.md`) | fixed shape | n/a |
| `~/.agents/summaries/*` | Daily summaries | newest 3 (`dailysummary.go:25`) | on write |
| `~/.agents/checks/suggestions.json` | Daily-check findings | 50 suggestions, 200 dismissals (`dailychecks.go:38,48`) | on write |
| `~/.agents-secrets/secrets.env`, `connections.json`, `provider-secrets.json` | Personal secrets, OAuth connections (Linux; the Keychain on a Mac), machine provider secrets | one per entry | the person edits them |
| `~/.agents-secrets/sessions/<agent>.json` | Session-only secrets | Values go at archive; the file goes at delete; orphans are swept at start (`sessionsecrets.go:221-275`) | archive, delete, start |

## 2. In each folder (`<folder>/.agents/`)

| Store | Holds | Bound | Swept |
|---|---|---|---|
| `attachments/` | Files attached to prompts | 500 MB per folder; 7 days if no kept transcript names the file; `.tmp` after 1 day (`attachments.go:27,28,34`) | hourly, at start, on write. **Only in folders that still have an agent** (`attachments.go:82-90`). |
| `dropbox/**` | Files handed to a workflow | 25 MB per file (`host.go:587`). **No total, count or age limit.** | never |
| `worktrees/<name>` + branch `agents/<name>` | Git worktrees agentsd makes | **none** | only explicit remove (`worktrees.go:673`, `moves.go:562`). Archive, merge-archive and delete leave them. |
| `reviews/runtimes/<rt>-<date>.md`, `workflows/assess-<id>.md` | Runtime assessment reports | **none** | never |
| `pins.json` | Pinned sessions and hidden views | 10 sessions, 50 hidden views (`pins.go:576,615`) | on write |
| `folder.json`, `policy.json`, `mcp.json`, `personas/`, `skills/`, `plugins/`, `workflows/`, `docs-maps.json`, `marketplaces.json`, `mcp.removed.json`, … | Folder configuration (meant to be committed) | small; `mcp.removed.json` capped (`mcpcatalog/files.go:26`) | edited in place |

## 3. Outside our folders

Agents starts these processes and tools, but it does not own what they store.

| Store | Holds | Bound | Cleared by |
|---|---|---|---|
| `~/.claude/projects/<slug>/<sid>.jsonl` (or `CLAUDE_CONFIG_DIR`, and `<root>/runtimes/accounts/claude/<id>`) | Claude's copy of each conversation | **none, because of a bug.** Erasure looks in `folders/`, not `projects/` (`agentsd/erasure.go:371-372`): **#3625**. 6.0 GB on Alex's Mac. | erasure, after #3625 is fixed |
| `~/.claude/{todos,file-history,session-env,debug}/<sid>*` | Claude's per-session extras | erased (`erasure.go:373-376`) | agent delete |
| `~/.codex/sessions/…/rollout-*-<sid>.jsonl` (or `CODEX_HOME`) | Codex's copy | erased (`erasure.go:381-382`) | agent delete |
| Grok, Copilot, OpenCode, Cursor and Antigravity session stores | Their copies | **none**, unless the adapter supports ACP `session/delete`; the code knows only Claude's and Codex's files (`erasure.go:302-310,367-386`) | — |
| `~/.claude/history.jsonl`, `~/.codex/*.sqlite`, `history.jsonl`, … | Runtime-wide history and indexes | **none** (not ours) | — |
| `~/.npm/_npx` | `npx` cache for the Claude ACP adapter (`agentsd/runtimes.go:45`) | npm's own | — |
| Docker images and named volumes for Docker workspaces | Images pulled, volumes | **none.** `docker rm -f -v` removes containers and anonymous volumes; images and named volumes stay (`workspacecommands/presets.go:89-95`). | — |
| DigitalOcean, Codespaces, EC2 and GCP machines | Cloud machines | **none in count or time**; no idle stop | only `delete_machine` |
| `~/.ssh/config`, one block per codespace | `gh codespace ssh --config` output | **none**; no code removes a block (`codespacessh/codespacessh.go:131-152`) | — |
| `~/Library/…/NativeMessagingHosts` | Chrome native messaging manifest | 1 file | — |
| `$TMPDIR/agents-*` (Go) | Git indexes, screenshots, ssh install scratch | removed with `defer` | function exit |
| `/tmp/agents-tunnels-<uid>-<pid>` | ssh control sockets | removed on clean stop. **A crash leaves one per pid.** | — |
| `$TMPDIR/agents-output-<id>.<ext>` (Mac window) | Background output opened in TextEdit (`App/Sources/Sidebar/BackgroundPane.swift:70-77`) | **none** | macOS temp purge only |
| `~/.Trash/<skill>` | Removed skills | the person's Trash | — |

The MCP servers in `cmd/*-mcp` write nothing to disk. Their state is in memory and capped (for
example, the WhatsApp inbox holds 1,000 items, `whatsappmcp/inbox.go:29`). Tokens come from the
environment.

## 4. On the control plane

The store is a folder (`~/Library/Application Support/Agents Control/store/`) or a bucket
(`s3://<bucket>/control/v1/…`, `Host/Sources/StoreChoice.swift:121,143`).

One hourly sweep (`controlplane/sweep.go:15-30,424`) deletes at most 1,000 objects a round, and
runs rounds until it is done. It sweeps audit and seals, codes, tombstones, orphans, usage, runs
and lineage, and it runs the backups' `pruneOrphans` once a day. **Joins, lockjoins, signins,
linkRequests, and policy, governance and remove requests are pruned only when read.**

`agents-control backup` copies all of `v1/` except `v1/leases/` and `v1/copies/`. A store copy or
handover also leaves out `v1/keys/` (`storecopy.go:21,25`).

### People, machines and clients

| Key | Holds | Bound | Swept |
|---|---|---|---|
| `v1/control.json` | Owner, endpoints, epoch, control key public parts, audit days | 1 | — |
| `v1/clients/<UUID>.json` | Name, kind, public key, last seen, APNs token, ≤16 Live Activity tokens (12 h each), Web Push subscription | **No count cap** on self-hosted (hosted: 5/50). Key life 90 days (`keylife.go:18`). | Tombstone 7 days. **A client whose key expired is kept for ever.** |
| `v1/machines/<id>.json` | Name, key, platform, version, owner, workspace | No cap (hosted: 2/20) | Tombstone 7 days. **An expired machine is kept for ever.** |
| `v1/people/<id>.json` | Name, role, sign-ins (email, login), SCIM part, old names (90 days) | No cap | A removed person goes after 14 days, **or never when they have a sign-in** (`records/records.go:307`, `sweep.go:164`) |
| `v1/groups/<id>.json` | Name, members | 1,000 (`groups.go:20`) | tombstone 7 days |
| `v1/projects/<id>.json` | Name, owner, slots, ≤20 boards | 500 per person (`projects.go:36`) | tombstone 7 days |
| `v1/projectFolders/<host>.json` | A machine's joined folders | 1,000 | orphan sweep |
| `v1/locks/<person>/<n>.json` | Machine-lock chain | 4,096 per person (`machinelock/lock.go:40`) | only on Reset. **Not deleted when the person is removed.** |
| `v1/users/<u>/settings.json`, `notices.json`, `secrets/<NAME>.json` | Person settings, notice bucket, sealed secrets | 256 KiB part, 16 KiB secret, 200 secrets (`usersettings/usersettings.go:45-49`) | on person removal |
| `v1/links/<channel>/<sha>.json` | Channel identity → person | **no cap** | on unlink or person removal |

### Requests, codes and sign-in

| Key | Holds | Bound | Swept |
|---|---|---|---|
| `v1/codes/<id>.json`, `.spent` | Purpose, owner, invite name and role, expiry | **No count cap**; only rate limited (2/s, burst 20, `limits.go:46-47`) | 24 h after expiry |
| `v1/joins/`, `v1/lockjoins/`, `v1/signins/` | Waiting join, lock-join and sign-in asks (keys, source IP) | 50 / 200 / 50 open, per-person caps; 10-minute life | 1 h after expiry, **on read only** |
| `v1/linkRequests/<id>.json` | Link asks | 50 open; 24 h | on read only |
| `v1/oidc/state/`, `v1/oidc/tickets/` | PKCE verifier, sealed refresh token | 10 / 2 minutes. **No count cap.** | 1 h, hourly |
| `v1/signin.json`, `v1/signin/providers/`, `v1/signin/domains/` | Sign-in settings, org OIDC providers, domain claims | 5 providers, 20 domains | on remove |
| `v1/signin/refresh/<person>/<prov>.json` | Sealed org refresh token | 1 per person per provider | person removal |
| `v1/scim/<prov>/names/<sha>.json` | userName → person | 1 per SCIM user | rename or delete. **Not on an admin's remove.** |
| `v1/scim/tokens/`, `v1/read/tokens/` | Token hashes, last-use IP | 2 live / 20; 10 live / 50 | trim on write |
| `v1/requests/remove/<user>.json` | SCIM delete → admin ask | 1 per person | removal or read |
| `v1/policy/requests/`, `v1/governance/requests/` | Budget and catalogue asks | 1,000 total; decided ones 30 days | on read |

### Work data

| Key | Holds | Bound | Swept |
|---|---|---|---|
| `v1/kept/<host>/<seq>-<id>.json` | Prompts and agent starts for a stopped workspace, **with attachments** | 20 per host, **waiting ones only** (`providers/kept.go:21,176`); each up to 40 MiB | on delivery or host removal. **Failed ones are never deleted.** |
| `v1/copies/<host>.json` | A host's last folders and agents (≤500, **with titles**) | 1 per host | on host forget |
| `v1/usage/hours/`, `v1/usage/days/` | Usage and cost by person, project, folder, machine, runtime | 7 days / 90 days (`reports.go:30-31`) | hourly |
| `v1/lineage/<host>.json` | Cost per issue, PR and session node | 5,000 nodes, 90 days (`lineagecost.go:25-28`) | on write |
| `v1/lineage-graph/<host>/links.json`, `states.json` | A machine's lineage links and its sessions' state changes (#4275) | Links by `lineage.Bound` (ended 90 days, 20,000); states as on the machine (90 days, each session's last, `lineage.MostStates`); a removed machine's after a day (`lineagegraph.go:31-36`) | on write, hourly |
| `v1/build-timings/<host>/<forge>/<path>/<day>.json`, `meta.json` | A machine's CI runs, jobs and steps of a repository: refs, times, conclusions, runner labels, names; no titles or logs (#5232) | As on the machine (`citimings`: 90 days, 20,000 runs a repository, PR steps 14 days), each day bounded on write; a stopped machine's swept once a day; a removed machine's after a day (`builds.go`) | on write, hourly |
| `v1/runs/<day>/<hash>.json` | Workflow trigger claims | 7 days; **no per-day cap** | hourly |
| `v1/reports/views/<user>.json` | Saved report views | 50 | person removal |
| `v1/providers/<id>.json` | Machine providers | **No cap. Tombstones are never swept.** | — |
| `v1/machine-names/<person>.json` | The person's machine-N counter (#3972), the provider New Machine uses and the options used last on each provider (#3979) | 1 per person: one number, one provider id, one set of options per provider | — (a number is never used again) |
| `v1/tunnels/<id>.json` | Server reverse tunnels | unjoined 15 minutes | on use |
| `v1/policy.json`, `v1/policy/versions/` | Org policy and old versions | 64 KiB; 100 versions | on write |
| `v1/governance/machines/`, `v1/governance/approvals/` | Installed servers and skills; approvals | 500 items; 1,000 approvals, **no expiry** | — |
| `v1/org/routes/<id>.json` + `.secret.json` | Org keys and gateways | 50 routes, 4 MiB sealed | tombstone swept |

### Audit, keys and backups

| Key | Holds | Bound | Swept |
|---|---|---|---|
| `v1/events/<day>/…` | Audit entries (who, method, host, target) | 90 days by default, 1–3,650 (`audit/audit.go:29-33`); hosted plans 7 / 90 days. **No size cap per day.** | hourly, by day |
| `v1/events/<day>/<ms>-<rand>.json` | **Mesh change events** (several copies only) | **The audit's days, so up to 10 years** (`mesh.go:675`) | same sweep |
| `v1/audit-seals/`, `v1/audit-sinks.json` | Daily chain heads; ≤4 SIEM sinks with sealed tokens | with the day; 4 | — |
| `v1/keys/control.sealed` (+ previous) | KMS-sealed control key | 2; previous after 30 days | — |
| `v1/backups.key` | Sealed key for server backups | 1 | — |
| `v1/backups/<owner>/<host>/<name>/…` | Servers' sealed backups (transcripts) | 8 MiB × 1,024 parts = 8 GiB a backup; Keep 1–10, **so up to ≈80 GiB a host**; a removed host's for 90 days (`backups.go:52-56`) | on commit, daily. Stray parts age by a **name time the host chooses**, so a future time never ages. |
| `v1/leases/`, `v1/copies/<copyID>.json` | Mesh leases and heartbeats | 30 s | orphan sweep |
| `handover/forwarding-*`, `handover/mark-*` | Move forwarding; move check marks | forwarding ≤30 days. **An abandoned mark stays for ever.** | — |
| `probe/<copy>-<hex>` | Start-up probe | removed with `defer`; a folder store sweeps after 1 h. **On S3, never.** | — |

## 5. The hosted service

| Key | Holds | Bound | Swept |
|---|---|---|---|
| `hosted/v1/accounts/<id>.json` | Sign-in provider and subject, login, plan, suspension, certificate time, **Stripe customer and subscription IDs** | 100 accounts (`hosted/signup.go:40`) | Delete Account |
| `hosted/v1/{github,apple,google}/<subject>.json` | Sign-in → account | 1 per account | Delete Account |
| `hosted/v1/invites/<code>.json` | Expiry and **who used it** | 14-day life | **never; survives Delete Account** |
| `hosted/v1/waiting/`, `waitlist/` | Waitlist | 10,000 | only on sign-up |
| `hosted/v1/allow/`, `blocked/` | Operator lists | operator | operator |
| `hosted/v1/stripe/<evt>.json` | Stripe events seen | 30 days, daily (`billing.go:25`) | daily |
| `hosted/v1/usage/<id>.json` | Account byte count | 1 per account | with the account |
| `accounts/<id>/v1/…` | That account's whole control-plane store (section 4) | Plan: storage 1 / 20 GB, machines 2 / 20, clients 5 / 50, events 7 / 90 days (`hosted/plans.go:37-40`) | Delete Account |
| `<dir>/<date>/<account>/…` (operator's disk) | Per-account backups | **none unless `--keep N`** (`cmd/agents-hosted/admin.go:162-191`) | — |

Sessions are signed cookies (30 days); the server keeps nothing for them.

## 6. Agents Host on the Mac

| Store | Holds | Bound |
|---|---|---|
| `~/Library/Application Support/Agents Control/` | `store/`, `tls/`, `secrets-key`, `apns.p8`, `web.json`, `control-key` (scratch) | fixed |
| `…/Agents Control/store-before-<…>` | A whole old store, set aside on a store switch or a move back (`Host/…/HostModel.swift:561,791`) | **none; never pruned.** Each holds the audit, sealed secrets and server backups. |
| Keychain `com.alexecollins.agentshost` | `control-key`, `bucket-keys`, `control-key-before-<unix>` | **`control-key-before-*` is added on each move back and never deleted** |
| `~/Library/Logs/Agents/control.log` | Control plane log | 4 MB + 1 older (`controlplane/log.go:20`) |
| Web Push VAPID key (`AGENTS_WEBPUSH_KEY_FILE`) | Push signing key | 1. **Not in `agents-control backup`**, so a restore breaks browser push. |

## 7. The clients

### Mac window

| Store | Holds | Bound | Cleared |
|---|---|---|---|
| Defaults `draft.agent.<uuid>`, `draft.new.<folder>`, `draft.start` | Unsent prompts and attachments, ≤512 KiB each | 30 days (`DraftStore.swift:29`); removed on archive (`App/Sources/Chat/DraftKeeper.swift:47,221`) | archive, 30 days, send |
| Defaults `newSessionProjectFolders` | Last folder per project | **none** | never |
| Defaults `sidebar.folds` / `folded` / `openSessions` | Sidebar fold state | `openSessions` 200; **fold sets none** | never |
| Defaults `sidebar.<window>.width` / `.pane` | Inspector size per folder window | **none** | never |
| Defaults `machineLockPin.<ctrlkey>` (+ `.lock`, `:<person>`) | Machine-lock pins and the stored lock | **none**; one set per control plane and person | only on a lock reset. **Not on Forget.** |
| Defaults display and UI choices | Fixed key set | fixed | — |
| Defaults domains `<bundle>.walk.*`, `.root.*` | A scratch copy's preferences | walk: when its folder is gone; root: 7 days (`WindowDefaults.swift:38`) | at launch |
| `…/Application Support/Agents/control-client.json` | Pairing (0600, not backed up) | 1 | Forget This Mac |
| Keychain `control-client-key`, `lock-signing-key` (+ `.walk.<name>`) | Client key, lock signing key | **one more per walk name, never removed** | never (Forget keeps the client key by design) |
| `WKWebsiteDataStore.default()` (browser pane) | Cookies, logins, localStorage, caches of every site any agent opened (`App/Sources/Sidebar/BrowserPane.swift:172`) | **none from the app** | never |
| Kokoro voice models (FluidAudio cache) | TTS models, copied or downloaded | **none**; can be hundreds of MB (`Shared/UI/Voice/KokoroVoice.swift:89-107`) | never |
| `~/Library/Logs/Agents/crashes/`, `hangs/` | Crash notes, hang stacks | 20 each | at launch |
| `$TMPDIR/agents-output-*` | See section 3 | none | — |

### Remote (iPhone and iPad)

| Store | Holds | Bound | Cleared |
|---|---|---|---|
| Defaults `draft.agent.<uuid>`, … | Unsent prompts and attachments, ≤512 KiB each | **none.** The Remote never calls `DraftStore.sweep`, so neither the 30 days nor archive applies. iOS loads all of `UserDefaults` at launch. | only on send |
| App group `Library/Caches/attention-snapshot.json` | The widget's needs-you rows **with headlines in plain text** | 12 rows; stale after 15 minutes | **not on Forget**: the widget keeps showing the old pairing |
| Defaults `machineLockPin.*`, `newSessionProjectFolders`, fold sets | As on the Mac | **none** | never |
| Defaults `liveActivityTurns` | Turns covered by the Live Activity | the activity's sessions | when the activity ends |
| `Library/Caches/remote.log` (+ `.1`) | Device log | 256 KiB × 2 | rotation |
| `Application Support/Agents/control-client.json` | Pairing | 1 | Forget This iPhone |
| Keychain `device-key` (shared group), `control-client-key`, `lock-signing-key` | Device and client keys | 1 each | never |
| Delivered notifications, categories | Banners | 32 categories | on reconnect; not on Forget |

### Web page

| Store | Holds | Bound | Cleared |
|---|---|---|---|
| IndexedDB `agents` | Non-extractable pairing key, lock signing key | 1 | Forget, re-pair, forgotten by the control plane |
| IndexedDB `agents-signin` | Pending org sign-in key (10 minutes) | 1 | on use; expiry checked on read |
| localStorage `agents.drafts` | Drafts | 40 drafts, 256 KiB attachments (`Web/src/model/drafts.ts:12,14`) | send; **not on Forget** |
| localStorage `agents-lock-pin`, `…:<person>` | Machine-lock pins | **none. Not keyed by control plane**, so a re-pair to another one reads the old pin. | never |
| localStorage folds, `newSession.projectFolders`, start form, UI choices | UI state | fold sets and project map **none** | never |
| sessionStorage filters and sort | Per tab | fixed | tab close |
| Service worker `/sw.js` + push subscription | Web Push (no offline cache) | 1 | **not on Forget** |

## 8. In memory

Only data that grows is listed here. Most in-memory caches have a bound; the ones without one
are in bold.

| Process | What | Bound |
|---|---|---|
| agentsd | **`d.sessionCost`** (`agentsd/cost.go:278`) | **none**: one entry per agent that ever cost, for the life of the process |
| agentsd | **`d.viewCalls`** (`views.go:128`) | 64 calls per agent; **agent keys never removed** |
| agentsd | **`undoNotes.byAgent`** (`turnundo.go:399`) | **none until the agent's next turn** |
| agentsd | **ACP terminal buffer** (`acp/session.go:811`) | 256 KiB default; **the runtime sets the limit, with no upper cap** |
| agentsd | Event consequences (`events.go:248`) | **no count cap** |
| agentsd | Held lines when the disk is full | 1 MiB per agent (`store/held.go:23`) |
| agentsd | Transcript line indexes, turns caches | 32 each |
| agentsd | Terminal scrollback | 4 MiB a terminal (`shells.go:34`) |
| control plane | **`notices.Desk.posted`** (`controlplane/notices/desk.go:29`) | **none**; a need that is never withdrawn (host crash) stays |
| control plane | **Peer `presence`** (`router.go:705`) | **none**: added by client ID, removed by session ID, so never removed |
| control plane | **`storecopy` `written`** (`storecopy.go:68`) | **the whole store in memory** during backup, store copy or handover, server backups included |
| control plane | Socket out-queue | 8,192 messages × 1,024 sockets, **by count, not bytes** (messages up to 40–64 MiB) |
| control plane | `readcache` | 40,000 entries, **by count, not bytes** |
| control plane | `clientRates` | 4,096, **soft** (only idle entries go) |
| control plane | Audit writer queue, sink outboxes, push queues | 10,000; 10,000 × 4; 256 (drop when full) |
| Mac + Remote | **`AgentsModel` entries, turns, artifacts, file changes** | 600 / 48 / 100, **but trimmed only while the chat follows the end** (`AgentsModel.swift:643`). A chat scrolled up or paged back grows without limit, once per popped-out window. |
| Mac + Remote | `recentEvents` | 1,000 on live insert; **paging back is not trimmed** (`AgentsModel.swift:1218`) |
| Mac | `ServerPictures`, `PinnedPage` pictures | 24 per host, **no byte limit** (the phone has 64 MiB) |
| Web | Chat history | 600–800 entries; paging back stops at 1,600 entries / 200 turns (`Web/src/model/store.ts:86-87`) |
| Web | **`events[host]`** (`store.ts:3561-3593`) | **none** in the page; each load merges into the list. The daemon's 10,000 is the real limit. |
| All clients | `chartHints`, `pageRevisions`, `leadAsked`, `startedPages` | **none**, small |

## 9. Unbounded data, ranked

Ranked by harm: deleted or private data that stays first, then disk and memory that can grow
large, then small leaks.

**A. Data a person deleted or forgot that stays**

1. **Claude transcripts are never erased** (6 GB here). Filed: **#3625** (`priority:high`).
2. Other runtimes' copies (Grok, Copilot, OpenCode, Cursor, Antigravity) are never erased unless
   the adapter has `session/delete`.
3. Forget / unpair leaves client data on every client: Remote widget headlines, drafts, lock
   pins, push subscription, browser-pane website data.
4. Control plane: a removed person with a sign-in is kept for ever, and their lock chain is too;
   failed kept requests (with attachments) are never deleted; hosted invites record who used
   them and survive Delete Account.
5. Mac Agents Host: `store-before-*` folders (whole old stores, audit and sealed secrets
   included) and `control-key-before-*` keychain items are never pruned.

**B. Large growth on disk**

6. Git worktrees (`.agents/worktrees/`): no bound at all (9 GB, 18 worktrees in this repo).
7. Server backups: up to ≈80 GiB per host on the control plane; a stray part with a future name
   never ages.
8. Folder dropbox: no total, count or age bound.
9. Docker images, named volumes and cloud machines: never removed or stopped on their own.
10. Browser profile (`<root>/browser/profile`) and the Mac browser pane's website data.
11. Transcripts themselves: no size bound per agent (bounded by agent retention only).
12. Other machines' backups in a shared backup folder; per-account hosted backups without `--keep`.
13. Mesh change events kept as long as the audit (up to 10 years).

**C. Large growth in memory**

14. `storecopy` holds the whole store in memory (server backups included).
15. Mac and Remote chats scrolled up grow without limit (the web caps at 1,600).
16. Control plane socket queues and `readcache` are counted, not sized.
17. `notices.Desk.posted` and peer `presence` on the control plane; `sessionCost`, `viewCalls`,
    ACP terminal buffers in agentsd.

**D. Small but never pruned**

18. `release-tags.json`, workflow states and their copies, `mcp-approvals.json`,
    `plugin-approvals.json`, `devices.json`, review files' folder keys.
19. `~/.ssh/config` codespace blocks; `roots/<name>-<hash>` cache and log folders; walk keychain
    items; `agents-output-*` temp files; Kokoro models.
20. Expired clients and machines, provider tombstones, governance approvals, codes and OIDC
    states (time-bounded but not count-bounded), handover marks, S3 probes.
21. Remote drafts (each up to 512 KiB, loaded at every launch).
22. Client preference maps: `newSessionProjectFolders`, fold sets, sidebar widths, lock pins.

**E. A bound that exists but is applied late**

23. Stores pruned only on read: control plane joins, lockjoins, signins, link, policy,
    governance and remove requests.
24. Stores pruned only at start or on the next use: workflow runs (at start), Outgoing/Incoming
    (next transfer), lineage (open or append growth), crash leftovers (`.restore-*`,
    `catalog-staging`, `browser/output`, tunnel sockets).
25. Bounds by keys, not by age: spend, usage, time and features keep the newest N keys, so an
    idle machine keeps older data.
26. `app-tools.jsonl` arguments are not cut; a single MCP log write over 1 MiB is written whole;
    a panic in `daemon.log` skips the limit.

**F. Correctness found on the way**

- Web lock pins are not keyed by control plane, so a re-pair reads the old pin.
- `appToolsPath` does not upper-case the agent ID (`agentsd/assess.go:174`); on Linux a
  lowercase ID writes outside the folder that Delete removes.
- The VAPID key is not in `agents-control backup`; a restore breaks browser push.

## 10. Where the docs are wrong

`docs/explanation/compliance/data-and-retention.md`:

- **"A backup holds … turn summaries"**, and the same for exports: false. `backups.go:69` reads
  `agents/<ID>/turns.jsonl`, which is never written; summaries are in `<cache>/turns/<ID>.jsonl`.
  The daemon can rebuild them from the transcript, so this is a doc error more than data loss.
- It does not say that `said.json` and `erased.json` are in a backup.
- **"The control plane holds no conversations"**: server backups (sealed transcripts), host
  copies (agent titles), kept requests (with attachments) and lineage nodes are in the same store.
- Clients and machines "until forgotten or removed": tombstones stay 7 days; expired ones stay for ever.
- Kept requests "20 a machine at most": failed ones are not counted and never expire.
- Hosted account data: it also keeps Apple and Google subjects, plan, suspension and Stripe IDs;
  Delete Account leaves used invites, operator backups and Stripe's records.
- Outgoing/Incoming "after an hour untouched", workflow runs "7 days", events "7 days and 10,000",
  spend "7 days": each is applied later or by keys (section 9, E).
- Attachments' 7-day rule applies only in folders that still have an agent.
- It leaves out most stores in sections 1–6 of this page, among them lineage, the cost and report
  ledgers, approvals, devices, the browser profile, worktrees, the dropbox's missing total bound,
  every control-plane record family except the six it names, the Mac's control-plane folder and
  keychain items, and the hosted service's own records.

`docs/reference/agents-folder.md` lists only `~/.agents` and the top of the data folder; it is
right for what it lists.
