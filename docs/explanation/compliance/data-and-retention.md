---
diataxis: explanation
devices: [mac, iphone, ipad, web, server]
description: "What each store of Agents keeps, how long and how large, when that bound is applied, how it is backed up and restored, and what is not backed up today."
---

# Data and retention

Agents keeps plain files, not a database. Most stores have a bound: a time, a count or a
size. Some have none. A conversation has none: it is kept until its agent is deleted. This
page lists the stores, then says what a backup holds and what it does not.

This page is the summary for readers. Engineers: the data inventory,
`specs/data-inventory/inventory.md` (#3653), gives each bound with its constant and its
`file:line`, and lists the clients and the memory as well.

**When a bound is applied** matters as much as the bound. A store pruned **on write** or
**hourly** stays near its bound. A store pruned only **at start**, **on read** or **on the
next use** can stay over it for as long as nothing starts, reads or uses it. Some bounds
count **keys**, not days: "90 days" means the newest 90 days that have data, so an idle
machine keeps older data.

## On each machine

A machine's data folder is `~/Library/Application Support/Agents` on a Mac and
`~/.local/share/Agents` on Linux (`~/.agents-server/root` on a server installed by its join
command). Only its user can read it (mode 0700). Its cache folder is
`~/Library/Caches/com.alexecollins.agents` and its log folder `~/Library/Logs/Agents` on a
Mac.

### Agents and conversations

| Store | What it keeps | How long, how large | Applied |
| --- | --- | --- | --- |
| `agents/<id>/agent.json`, `transcript.jsonl` | Each agent's record and its whole conversation | Until the agent is deleted. An archived agent is deleted after **Archived agents** (7, 14, 30 or 90 days, or Forever; 30 by default). A pinned agent is kept. A conversation has no size limit, on purpose: Archived agents bounds it (#3648). | At start, then hourly |
| `agents/<id>/app-tools.jsonl` | Each call to the app's own tools | With the agent. Each argument and the answer are cut to 2,000 characters. | With the agent |
| `agents/<id>/said.json` | A search index of what was said | 32 KiB, with the agent | On write |
| `turns/<id>.jsonl`, in the cache folder | A summary of each turn | With the agent. Made again from the transcript when it is missing. | With the agent |
| `erasures.json` | Runtime copies of deleted agents still to erase | 1,000 entries, 3 tries, 7 days | On write |
| `erased.json` | Every agent deleted here | 10,000 IDs for 400 days | On write |
| `elsewhere.json` | Sessions started on or from other machines | 200 a list | On write |

### Events, usage, cost and lineage

| Store | What it keeps | How long, how large | Applied |
| --- | --- | --- | --- |
| `events.jsonl` | The machine's events | 7 days, and 10,000 events (pruned when it reaches 10,500). The consequences of an event have no count limit. | At start, hourly and on write |
| `events-state.json` | Branch tips that `branch.moved` compares, cost crossings, disk levels | The live folders, and today only | On write |
| `usage-history.json` | Usage and cost | The last 168 hours and 90 days, by date | On write and hourly (#3686) |
| `time-history.json` | Time, recaps and records | The last 168 hours, 90 days and 90 recaps, by date | On write and hourly (#3686) |
| `spend.json` | Spend for the cost limits | The last 7 days, by date | On write and hourly (#3686) |
| `report-hours.json` | Hourly totals sent to the control plane | 8 days | On write |
| `features-history.json` | How often each feature is used | The last 90 days, by date | On write and hourly (#3686) |
| `lineage.jsonl` | Links between issues, PRs, sessions and deploys | Ended links 90 days, 20,000 links | When it opens, when it grows by 2,000, and hourly (#3649) |
| `lineage-cost.json` | Cost of each lineage node | 90 days, 5,000 nodes | On write |
| `lineage-comments.json` | Cost comments on PRs | 500, 30 days | On write |
| `release-tags.json` | Release tags already linked, for each repo | The newest 50 for each repo; an older tag counts as linked (#3652) | On write |
| `achievements.json` | Milestones | A fixed set | — |

### Workflows, assessments, approvals and devices

| Store | What it keeps | How long, how large | Applied |
| --- | --- | --- | --- |
| `workflows.json`: runs | Workflow runs | 7 days, unless its agent still works | At start, when a run ends, and hourly (#3649) |
| `workflows.json`: states | A state for each folder and workflow ever seen | 30 days after its workflow file goes (#3652) | Hourly, and the app's **Remove** |
| `workflow-copies/` | The approved text of each workflow and its skills | The copies that the states name; an older version goes when one is saved | On write |
| `assessments/` | Each runtime assessment's start, score and scope | The newest 50 | When one starts |
| `mcp-events.json` | MCP event IDs already seen | 2,000 IDs, 7 days | On write |
| `mcp-views/` | View catalogues | Pruned to the live servers | On write |
| `mcp-approvals.json`, `plugin-approvals.json` | Digests of approved MCP servers and plugins | The folders that exist: a folder that is not on disk and not in the app goes (#3652) | Hourly; MCP also on remove |
| `devices.json` | Paired devices | 90 days after a device was last seen (#3652) | Hourly, and **Forget** |
| `review-dismissals.json`, `review-opened.json` | PR links for each folder | 200 a folder; a folder that is not on disk and not in the app goes (#3652) | On write, and hourly |
| `lock-seen.json` | IDs of signed requests already seen | 4,096 | On write |
| `attention.json` | What needs you, and what was delivered | The live needs | On write |
| `leases.json`, `resources.json` | Resource leases | 240 minutes a lease; dropped when its agent stops | On write |
| `guarded-files.json` | Guarded file states | The folders that exist | On write |
| `org-routes/`, `runtimes/org/` | Org key routes and their stand-in homes | 50 routes | On delivery |
| `runtimes/accounts/<runtime>/<id>/` | The home of each runtime account you added, **with that runtime's own transcripts** | Until the account is removed | On remove |
| `browser/profile/` | One browser profile for every browser sign-in, and its caches | Sign-ins until the site ends them or you clear the site in Settings ▸ Browser. The caches are emptied before each start, and the HTTP cache stays under 64 MB while it runs (#3727). | At each browser start |
| `folders.json`, `policy*.json`, `backup-settings.json`, `settings/`, and other small files | Configuration | A fixed shape | — |
| `<file>.unreadable-<time>`, `<file>.corrupt-<time>` | A store that could not be read, set aside | The newest 3 of each kind for each file | On write |

### Transfers, backups and staging

| Store | What it keeps | How long, how large | Applied |
| --- | --- | --- | --- |
| `backups/<machine>/` | This machine's backups | The newest **Keep** (1 to 10, 3 by default); a `.tmp` after 24 hours. Another machine's backups in a shared backup folder go 90 days after its newest (#3648). | After each backup |
| `backups-upload/`, `backups-download/` | A server backup on its way | Removed after use | On use |
| `.restore-*` | A restore in progress | Removed when it ends; one a crash left goes at the next start (#3649) | At end; at start |
| `Outgoing/`, `Incoming/` | Exports, sends and imports | 1 hour untouched | On the next transfer, at start and hourly (#3649) |
| `Clones/<id>` | A clone in progress | Removed after the clone | After the clone, and at start |

### Caches and logs

| Store | What it keeps | How long, how large | Applied |
| --- | --- | --- | --- |
| `daemon.log`, in the log folder | What the machine did | 4 MB, and one older file. Output from a crash is checked against the limit within 30 seconds. | On write |
| `mcp-logs/`, in the log folder | What each hosted MCP server wrote to stderr | 1 MB and one older file a server, and the newest 32 servers. A larger write is split, so no file passes 1 MB. | When a server starts |
| `tools/<runtime>/`, in the cache folder | Pinned runtime toolsets | The current one | At start |
| `browser/`, in the cache folder | The browser that agents drive, and its output | Old browser versions are left to Playwright. Output goes when the session ends; what a crash left goes at the next start (#3649) | On install; at session end; at start |
| The Mac browser pane's website data (WebKit's default store) | The sign-ins of every site the pane opened, and its caches | Sign-ins until the site ends them. The caches are emptied once each time the app starts (#3727). | At the first pane of each launch |
| `catalog-staging/`, in the cache folder | Skill previews | 8 previews, 30 minutes; folders left by a restart go at the next start (#3649) | On use; at start |
| `option-cache.json`, in the cache folder | Runtime options | 50 | On write |
| Cache and log folders of each other data folder (`roots/<name>-<hash>`) | As above, for a second copy | Removed when that data folder is gone (#3746). Each keeps its data folder's path in `root-path`; a folder made before that is kept, and so is one whose data folder's parent is gone too, as on a disk that is not attached. | Hourly, by a machine whose data folder is not a temporary one |
| Terminal scrollback | What a terminal showed | In memory only, 4 MiB a terminal | On write |

### `~/.agents` and `~/.agents-secrets`

| Store | What it keeps | How long, how large | Applied |
| --- | --- | --- | --- |
| `~/.agents/settings/` | Settings that follow you (see [The `~/.agents` folder](../../reference/agents-folder.md)) | A fixed shape | — |
| `~/.agents/summaries/` | Daily summaries | The newest 3 | On write |
| `~/.agents/checks/suggestions.json` | Daily-check findings | 50 findings, 200 dismissals | On write |
| `~/.agents-secrets` | Secrets, connections and machine provider secrets (see [Security overview](security-overview.md#where-secrets-live)) | Until you remove them | — |
| `~/.agents-secrets/sessions/<agent>.json` | Secrets for one session | The values go when the agent is archived; the file goes when it is deleted | On archive and delete; leftovers at start |

## In each folder

These are in `<folder>/.agents/`.

| Store | What it keeps | How long, how large | Applied |
| --- | --- | --- | --- |
| `attachments/` | Files attached to prompts | A file that no kept conversation names goes after 7 days. The folder stays under 500 MB, oldest first. A folder with no agent left is swept too: `attachment-folders.json` lists each folder an attachment was written in, until it holds none (#3649). | At start, hourly and on write |
| `dropbox/` | Files handed to a workflow | 25 MB a file and 500 MB a folder from **dropbox/put**; a put past the total is refused. A cut-off put's `.part` after 24 hours. **A file put there is the person's: no age limit** (#3648). | On put; hourly |
| `worktrees/<name>`, and branch `agents/<name>` | Git worktrees that agents made | The worktree goes when its agent is deleted, or archived with its branch merged into its base (or archived because its pull request merged, when no commit of its branch is missing from a remote). The branch goes only when it is merged. A worktree with uncommitted or untracked changes, one that another agent's record names, and one the app did not make are always kept (#3726). | On archive and delete; when removed |
| `reviews/runtimes/`, `workflows/assess-<id>.md` | Runtime assessment reports | **None** | Never |
| `pins.json` | Pinned sessions and hidden views | 10 sessions, 50 hidden views | On write |
| `folder.json`, `policy.json`, `mcp.json`, `personas/`, `skills/`, `workflows/` and the like | The folder's configuration, meant to be committed | Small | — |

## Outside our folders

Agents starts these tools. It does not own what they keep.

| Store | What it keeps | How long, how large |
| --- | --- | --- |
| `~/.claude/projects/` (or `CLAUDE_CONFIG_DIR`) | Claude's copy of each conversation | **Not erased today:** erasure looks in the wrong folder (#3625) |
| `~/.claude/todos`, `file-history`, `session-env`, `debug` | Claude's files for each session | Erased when the agent is deleted |
| `~/.codex/sessions/` (or `CODEX_HOME`) | Codex's copy of each conversation | Erased when the agent is deleted |
| `~/.grok/sessions/`, `~/.copilot/session-state/`, `~/.cursor/acp-sessions/`, and Antigravity's `conversations/` and `brain/` in its own home | Grok's, Copilot's, Cursor's and Antigravity's copy of each conversation | Erased when the agent is deleted (#3647). Copilot's index, `session-store.db`, keeps the session's row |
| OpenCode's `opencode.db` | OpenCode's copies, all in one SQLite file | **Not erased**, unless OpenCode can delete a conversation (ACP `session/delete`). When it cannot, the Delete confirmation says so on every client (#3669) |
| `~/.claude/history.jsonl`, Codex's history and indexes | Each runtime's own history | **Not erased** |
| Docker images and named volumes | What Docker workspaces pulled and kept | **Delete Machine** removes the workspace's container, its volumes and its image, when no other container uses them (#3728). Docker keeps an image with a second tag or a child image. |
| DigitalOcean, Codespaces, EC2 and GCP machines | Cloud machines | **No limit in count or time, and no stop when idle.** Only **Delete Machine** removes one. |
| `~/.ssh/config` (or `AGENTS_SSH_CONFIG`) | A block for each codespace | A codespace's block goes when **Delete Machine** deletes it (#3746). A codespace deleted outside Agents keeps its block. The one block that agentsd keeps for all codespaces is written again each time it prepares ssh. |
| `/tmp/agents-tunnels-<uid>-<pid>` | ssh control sockets | Removed at a clean stop; one whose process is gone goes when a control plane's tunnels start (#3649) |
| `$TMPDIR/agents-output-*` | Output that the Mac window opened in TextEdit | **None**; macOS clears its temporary folder |

## On the control plane

The control plane's store is a folder or an S3-compatible bucket. **It holds conversation
data:** servers' backups (their transcripts, sealed), each machine's last list of folders
and agents (with agent titles), prompts waiting for a stopped workspace (with their
attachments), and lineage nodes (each issue, PR and session it links, with its cost).

One sweep runs every hour. It removes old audit days, codes, tombstones, records with no
owner, usage, workflow runs and lineage, join, lock-join, sign-in and link requests, and
policy, governance and remove requests (#3649), and once a day the backups of removed
servers. It also forgets clients and machines whose key expired 90 days ago, and removes
the approvals of people and groups that are gone, and probes and move marks left by a
copy that stopped (#3748).

A removed client, machine, group, project, route or machine provider leaves a **tombstone** for 7 days, so
the other copies of the control plane learn that it went.

### People, machines and clients

| Records | What they keep | How long, how large | Applied |
| --- | --- | --- | --- |
| Clients | Name, kind, public key, when last seen, push tokens (APNs, up to 16 Live Activity tokens of 12 hours each, Web Push) | Until forgotten, then a tombstone for 7 days. A key lives 90 days; a client whose key expired is forgotten 90 days later (#3748). No count limit on a control plane of your own (hosted: 5 or 50). | Hourly |
| Machines | Name, key, platform, version, owner, workspace | Until removed, then a tombstone for 7 days. A machine whose key expired is removed 90 days later; a started machine's workspace stays (#3748). No count limit (hosted: 2 or 20). | Hourly |
| People | Name, role, sign-ins (email, login), SCIM data, old names for 90 days | A removed person goes after 14 days. One with a sign-in is kept, so that sign-in stays refused, but only as a tombstone: the ID, kind, role and each sign-in's provider and account (#3647) | Hourly |
| Groups, projects | Name and members; name, owner, slots and boards | 1,000 groups; 500 projects a person | Tombstone, hourly |
| Projects' folders | Each machine's joined folders | 1,000 | Hourly |
| Machine locks | Each person's lock chain | 4,096 entries a person. Deleted when the person is removed (#3647) | On **Reset** and on remove |
| A person's settings and secrets | Settings that follow a person; secrets, sealed | 256 KiB of settings, 200 secrets of 16 KiB | When the person is removed |
| Channel links | Which person a channel identity is | No count limit | On unlink or when the person is removed |

### Requests, codes and sign-in

| Records | What they keep | How long, how large | Applied |
| --- | --- | --- | --- |
| Codes | A code's purpose, owner and expiry, and an invite's name and role; never its secret | Deleted 24 hours after it expires. 1,000 codes; a new one over that is refused (#3748). | Hourly |
| Join, lock-join and sign-in requests | The asking key and its address | 10 minutes; 50, 200 and 50 open | On read and hourly, 1 hour after expiry |
| Link requests | A channel link that waits | 24 hours; 50 open | On read and hourly, 24 hours after expiry |
| Sign-in state | PKCE state and sealed refresh tokens while a sign-in runs | 10 and 2 minutes; 1,000 sign-ins started, each with at most one ticket (#3748) | Hourly, 1 hour after expiry |
| Sign-in settings | Org OIDC providers, domain claims, one sealed refresh token a person and provider | 5 providers, 20 domains | On remove |
| SCIM and read tokens | Token hashes, address of last use | 2 live of 20; 10 live of 50 | On write |
| Policy, governance and remove requests | Asks for a budget, a catalogue item, or removal of a person | 1,000; a decided one 30 days | On read and hourly |

### Work data

| Records | What they keep | How long, how large | Applied |
| --- | --- | --- | --- |
| Kept requests | Prompts and agent starts for a stopped workspace, **with their attachments** (up to 40 MiB each) | Until the machine starts and takes them, or is removed; 20 a machine, failed ones included (a new one pushes out the oldest that failed). One that failed goes after 7 days (#3647) | On delivery, on keep, hourly |
| Host copies | Each machine's last folders and agents, up to 500, **with titles** | One a machine | When the machine is forgotten |
| Usage reports | Usage, cost and time by person, project, folder, machine and runtime | 7 days by the hour, 90 days by the day | Hourly |
| Lineage | Cost of each issue, PR and session node | 5,000 nodes, 90 days | On write |
| Workflow runs | Which machine took each workflow trigger | 7 days | Hourly |
| Report views | Saved report views | 50 a person | When the person is removed |
| Machine providers | Each provider | No count limit. A removed one's tombstone for 7 days (#3748) | Hourly |
| Tunnels | Servers' reverse tunnels | 15 minutes unjoined | On use |
| Policy | The org policy and its old versions | 64 KiB; 100 versions | On write |
| Governance | Installed servers and skills; approvals | 500 items; 1,000 approvals. An approval stays until an admin takes it back, or its person or group is gone (#3748) | Hourly |
| Org keys and gateways | Routes and their sealed secrets | 50 routes | Tombstone, hourly |

### Audit, keys and backups

| Records | What they keep | How long, how large | Applied |
| --- | --- | --- | --- |
| Audit events | Who did what (see [Security overview](security-overview.md#who-did-what)) | 90 days by default; an admin sets 1 to 3,650 days (hosted: 7 or 90). No size limit a day. | Hourly, by day |
| Change events between copies | What changed, when the control plane has several copies | 1 day, in `v1/mesh/events/` (#3648) | Hourly, by day |
| Audit seals and sinks | Each day's chain head; up to 4 SIEM sinks with sealed tokens | With the day; 4 sinks | Hourly |
| Keys | The sealed control key and the previous one; the sealed key for server backups | 2; the previous one 30 days | — |
| Server backups | Servers' sealed backups (their transcripts) | The newest **Keep** of each server (1 to 10). At most 20 GiB a server, the newest always kept; a backup over 20 GiB is refused (#3648). A removed server's for 90 days after its newest. A cut-off backup's parts after a day; a name more than a day ahead is refused, and its parts deleted. | After each backup, and daily |
| Leases and heartbeats | Which copy holds what | 30 seconds | Hourly |
| Move forwarding and marks | Where a moved control plane went | Forwarding 30 days. A mark, and a start-up probe, left by a copy that stopped: 1 to 2 hours (#3748) | Hourly |

## The hosted service

On the hosted service, each account has a control plane store of its own (above), and the
service keeps these records.

| Records | What they keep | How long, how large |
| --- | --- | --- |
| Account | Sign-in provider (GitHub, Apple or Google) and its user ID, login, plan, suspension, certificate time, **Stripe customer and subscription IDs**, the date it signed up | Until **Delete Account**. 100 accounts. |
| Sign-in links | Which account a GitHub, Apple or Google user is | Until **Delete Account** |
| Account usage | The bytes the account's store holds | Until **Delete Account** |
| The account's control plane store | All of the section above | Plan limits: 1 or 20 GB, 2 or 20 machines, 5 or 50 clients, audit 7 or 90 days. Until **Delete Account**. |
| Invites | Expiry, and **who used it** | 14 days to use it. Kept after use, until **Delete Account**. |
| Waitlist | Who asked to join | 10,000; removed on sign-up |
| Stripe events | Stripe event IDs already seen | 30 days, swept daily |
| Operator backups | Each account's store, on the operator's disk | The newest 7 by default; `--keep N` sets it, `--keep 0` keeps all (#3648) |

The service keeps nothing for a signed-in browser: a session is a signed cookie for 30 days.

**Delete Account** stops the account's control plane, deletes its store, its usage, the
invites its sign-in used, the account and its sign-in link. It does not delete the
account's machines. It leaves the operator's backups of it, and Stripe's own records.

## Agents Host on the Mac

| Store | What it keeps | How long, how large |
| --- | --- | --- |
| `~/Library/Application Support/Agents Control/` | The control plane's store, TLS certificate, `secrets-key`, push key, web settings | One of each |
| `Agents Control/store-before-<…>` | A whole old store, set aside when you change the store or move back. Each holds the audit, sealed secrets and server backups. | The newest 2; an older one is deleted when another is set aside (#3671) |
| Keychain `com.alexecollins.agentshost` | The control key, bucket keys, and `control-key-before-<time>` | One of each; the newest 2 `control-key-before-*` items, deleted with the old stores (#3671) |
| `~/Library/Logs/Agents/control.log` | What the control plane did | 4 MB, and one older file |
| The Web Push key | The key that signs browser push | One. In `agents-control backup` as `webpush-key.pem` (#3651). |

## On each client

What the Mac window and the Remote keep in their defaults, and the web page in
`localStorage`, by folder and by control plane (#3750).

| Store | What it keeps | How long, how large | Applied |
| --- | --- | --- | --- |
| Sidebar folds (`sidebar.folds`, `sidebar.folded`, each scope; `agents.sidebar.folds`, `agents.sidebar.folded` on the web page) | Which folders and folds are open | The folders that exist. A folder that its machine no longer lists goes; all of a machine's go when the control plane no longer lists the machine. An offline machine's stay. The Remote lists no archived folders, so their folds go there. | When a machine lists its folders, and when it leaves |
| Open sessions (`sidebar.openSessions`) | Sessions whose children are shown | 200 | On write |
| `sidebar.folder.<folder>.width`, `.pane` (Mac only) | A folder window's inspector width and pane | As the folds | As the folds |
| `newSessionProjectFolders` (`agents.newSession.projectFolders` on the web page) | New Session's last folder for each project | As the folds | As the folds |
| `machineLockPin.<key>` (`agents-lock-pin.<key>` on the web page) | The machine-lock pins, the lock and each person's | This control plane's only: another control plane's go once the client is paired (#3750), and all go on **Forget** (#3670) | When the control plane answers |

## In memory

What a process holds while it runs, and goes when it stops. Each has a bound (#3650).

| Process | What it holds | How large |
| --- | --- | --- |
| Machine | A session's running cost, its views' calls, its undo notes | Until the agent is archived or deleted; 64 view calls and 21 undo notes an agent |
| Machine | A terminal a runtime asks for | The limit the runtime asks for, 4 MiB at most |
| Control plane | A store copy, backup or handover | One record at a time, and a hash of each record to check the copy |
| Control plane | A socket's lines waiting to go | 8,192 lines and 64 MiB; a slower socket is closed |
| Control plane | Records read for reports and the Console | 40,000 records and 256 MiB |
| Control plane | Notifications posted to devices | A week, and 10,000 at most |
| Control plane | Presence reported at another copy | Until no copy links the client |
| Mac, Remote, web | A chat's history | 600 to 800 entries while it follows the end; paging back stops at 1,600 entries and 200 turns |
| Mac, Remote, web | Events | 1,000 as new ones come; paging back stops at 5,000 |
| Mac, Remote | Pictures in a page | 64 MiB |

## Erasure

**Delete** works on an archived agent. It stops the agent's runtime, takes back its tokens,
and deletes its folder (record, conversation, tool log, search index) and its turn
summaries. Then (T8, #1001):

- **The runtime's own copy goes.** The machine starts the runtime as the agent ran (with
  its account) and asks it to delete the conversation (ACP `session/delete`). For Claude
  and Codex it also removes the session's files in the runtime's folder (`~/.claude` or
  `CLAUDE_CONFIG_DIR`; `~/.codex` or `CODEX_HOME`). Today Claude's conversation file stays
  (#3625). This waits in `erasures.json` in the data folder: 1,000 at most, done one at a
  time, and tried again at the next start when the runtime does not answer, 3 times at
  most within 7 days.
- **A restore never brings the agent back.** `erased.json` in the data folder names every
  agent the machine deleted: 10,000 at most, each for 400 days. A backup carries it, and a
  restore skips each agent in it, also on a new machine.

These stay behind:

- the copy of a runtime whose files are not known and that cannot delete a conversation
  (the Delete confirmation says so, #3669);
- attachments, until the next sweep finds no conversation that names them;
- the agent's events, until they are 7 days old;
- the agent's title in its machine's host copy on the control plane, until a window next
  lists that machine's agents;
- its lineage nodes and cost, until they age out (90 days);
- the backups that hold it, on the machine and on the control plane, until they age out (a
  restore skips it).

**Forget** removes a client's pairing: **Forget This Mac**, **Forget This iPhone**,
**Forget This Browser**, or the control plane when it forgets the client. The client then
also deletes what it kept of that control plane (#3670):

- **The Mac window:** its drafts and the start form, and its machine-lock pins.
- **The Remote:** its drafts, its machine-lock pins, the widget's file
  (`attention-snapshot.json`, with its headlines) and the badge, the Live Activity and its
  turns, and every banner it showed.
- **The web page:** its drafts and machine-lock pins in `localStorage`, and its Web Push
  subscription.

Each client keeps its machine-lock pins by control plane (`machineLockPin.<key>` on the Mac
and the Remote, `agents-lock-pin.<key>` on the web page, #3651), so a pairing with another
control plane does not read the old one's pins.

The Mac and the Remote keep their own key in the keychain, so that a new pairing can use
it. The web page deletes its key.

## Export and import

**Export…** in an agent's menu, and **Export Agents…** in a folder's, on the Mac, the
Remote and the web page, give a `.tar.gz` of the agent, or of every agent of the folder
(T8, #1001). It is in the backup format: each agent's record, conversation, tool log and
search index. It holds no turn summaries (the machine makes them again from the
conversation), no secret, no usage history and no other agent.

**Import Agents…** in a folder's menu sends the file to that folder's machine. Its agents
come back archived, to read and search. They are never run there, and bring no MCP servers.
An agent that the machine has already, or that it deleted (`erased.json`), is skipped.

The machine makes an export in its `Outgoing` folder and an import arrives in `Incoming`.
Each goes once it is read or imported. One left untouched for an hour goes at the next
export, send or import, at the next start, or at the hourly sweep.

## Backups

See [Back up and restore a machine](../../how-to/back-up-and-restore.md).

- **A machine** backs up every day by default, and keeps the newest 3 (1 to 10). A backup
  holds each agent's record, conversation, tool log and search index, and the usage and
  time history and the list of deleted agents (`erased.json`). It holds no sign-in, key or
  secret, and no turn summaries: the machine makes them again from the conversation.
- **A Mac** backs up to a folder, `backups` in its own data folder by default. That is the
  same disk: it undoes a mistake, but does not survive the loss of the Mac. Choose a second
  disk or a synced folder. Local backups are not encrypted.
- **A server** backs up to the control plane's store, sealed. The copy on the server is
  deleted once it is sent.
- **Restore** brings agents back archived, to read and search. An agent from another machine
  is shown, never run.

## What is not backed up today

The first HADR review (2026-10-21, #1557) found these. Each one is an open issue.

- **The control plane in the cloud is one VM with one disk**, with no snapshot and no copy
  (#2136). Losing that disk makes every device and machine pair again, and loses every
  server backup in its store.
- **A copy of the store does not restore a control plane on its own** (#2137). A restore
  also needs the control key, the `secrets-key` and the TLS certificate from the old home.
  With all of them, a machine joined again in 26 seconds in the review's drill.
  `agents-control backup` also holds the Web Push key (#3651), so browser push goes on
  after a restore.
- **Machine providers' secrets are on the machine that carries each provider** (#3398), not
  on the control plane. A copy of the store does not carry them, and nor does a machine's
  backup: when that machine is lost, add the provider again on another one.
- **A machine's backups are on its own disk by default** (#2139).
- **Not in a machine's backup:** turn summaries (made again), settings, workflows, secrets,
  attachments, events, lineage, approvals and the runtimes' own session files. A folder's
  `.agents/` folder is in the folder, and so in its git repository if you commit it.
- **Writes that are not synced.** Appends to a machine's events, its records' logs and its turn summaries
  are not synced to disk one by one, so a power cut can lose the last lines.

## Related

- [Data flow](data-flow.md)
- [Security overview](security-overview.md)
- [Back up and restore a machine](../../how-to/back-up-and-restore.md)
- [The `~/.agents` folder](../../reference/agents-folder.md)
