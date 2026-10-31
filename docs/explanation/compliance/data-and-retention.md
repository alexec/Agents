---
diataxis: explanation
devices: [mac, iphone, ipad, web, server]
description: "What each store of Agents keeps, how long and how large, how it is backed up and restored, and what is not backed up today."
---

# Data and retention

Agents keeps plain files, not a database. Most stores have a bound: a time, a count or a
size. A conversation has none: it is kept until its agent is deleted. This page lists the
stores, then says what a backup holds and what it does not.

## On each machine

A machine's data folder is `~/Library/Application Support/Agents` on a Mac and
`~/.local/share/Agents` on Linux (`~/.agents-server/root` on a server installed by its join
command). Only its user can read it (mode 0700).

| Store | What it keeps | How long, how large |
| --- | --- | --- |
| `agents/<id>/agent.json`, `transcript.jsonl` | Each agent's record and its whole conversation | Until the agent is deleted. An archived agent is deleted after **Archived agents** (7, 14, 30 or 90 days, or Forever; 30 by default). A pinned agent is kept. |
| `agents/<id>/app-tools.jsonl` | Each call to the app's own tools, with answers cut to 2,000 characters | With the agent |
| Turn summaries, in the cache folder | A line for each turn | With the agent |
| `events.jsonl` | The machine's events | 7 days, and 10,000 events at most |
| `usage-history.json`, `time-history.json` | Usage, cost and time | 168 hours by the hour, 90 days by the day |
| `spend.json` | Spend for the cost limits | 7 days |
| `workflows.json` | Workflows and their runs | A run is kept 7 days, or until its agent is archived or gone |
| `workflow-copies/` | The approved text of each workflow and its skills | The copies that `workflows.json` names; an older version goes when it is saved |
| `assessments/` | Each runtime assessment's start, score and scope | The newest 50 |
| `mcp-logs/`, in the log folder | What each hosted MCP server wrote to stderr | 1 MB and one older file a server, and the newest 32 servers |
| `events-state.json` | The branch tips that `branch.moved` compares | The live folders only |
| `<file>.unreadable-<time>`, `<file>.corrupt-<time>` | A store that could not be read, set aside | The newest 3 of each kind for each file |
| `<folder>/.agents/attachments` | Files attached to prompts | A file that no kept conversation names goes after 7 days. The folder stays under 500 MB, oldest first. |
| `<folder>/.agents/dropbox` | Files handed to a workflow | 25 MB a file. Not swept. |
| Terminal scrollback | What a terminal showed | In memory only, 4 MiB a terminal |
| `daemon.log` | What the machine did | 4 MB, and one older file |
| `erasures.json`, `erased.json` | Runtime copies of deleted agents still to erase; every agent deleted here | 1,000 entries for 7 days; 10,000 IDs for 400 days |
| `~/.agents-secrets` | Secrets (see [Security overview](security-overview.md#where-secrets-live)) | Until you remove them |

## On the control plane

The control plane's store is a folder or an S3-compatible bucket. It holds no conversations.
The one exception is a prompt sent to a stopped workspace: it waits in the store until
that machine starts.

| Records | What they keep | How long |
| --- | --- | --- |
| Clients, machines, people, groups | Who is paired, with their public keys, names and when last seen; which machines there are; a client's push tokens | Until forgotten or removed |
| Codes | A code's purpose, owner and expiry, never its secret | Deleted 24 hours after it expires |
| Audit events | Who did what (see [Security overview](security-overview.md#who-did-what)) | 90 days by default; an admin sets 1 to 3,650 days |
| Usage reports | Usage, cost and time by person, project, folder, machine and runtime, sent by each machine | 7 days by the hour, 90 days by the day |
| Kept requests | Prompts and agent starts for a stopped workspace | Until the machine starts and takes them; 20 a machine at most |
| A person's settings and secrets | Settings that follow a person; secrets, sealed | Until changed |
| Server backups | See below | The newest **Keep** of each server; a removed server's for 90 days after its newest |

On the hosted service, an account keeps its GitHub user id, its GitHub login and the date it
signed up. **Delete Account** stops its control plane and deletes everything under that
account, then the account. It does not delete the account's machines.

## Erasure

**Delete** works on an archived agent. It stops the agent's runtime, takes back its tokens,
and deletes its folder (record, conversation, tool log) and its turn summaries. Then
(T8, #1001):

- **The runtime's own copy goes.** The machine starts the runtime as the agent ran (with
  its account) and asks it to delete the conversation (ACP `session/delete`). For Claude
  and Codex it also removes the session's files in the runtime's folder (`~/.claude` or
  `CLAUDE_CONFIG_DIR`; `~/.codex` or `CODEX_HOME`). This waits in `erasures.json` in the
  data folder: 1,000 at most, done one at a time, and tried again at the next start when
  the runtime does not answer, 3 times at most within 7 days.
- **A restore never brings the agent back.** `erased.json` in the data folder names every
  agent the machine deleted: 10,000 at most, each for 400 days. A backup carries it, and a
  restore skips each agent in it, also on a new machine.

These stay behind:

- the copy of a runtime whose files are not known and that cannot delete a conversation;
- attachments, until the next sweep finds no conversation that names them;
- the agent's events, until they are 7 days old;
- the backups that hold it, until they age out (a restore skips it).

## Export and import

**Export…** in an agent's menu, and **Export Agents…** in a folder's, on the Mac, the
Remote and the web page, give a `.tar.gz` of the agent, or of every agent of the folder
(T8, #1001). It is in the backup format: each agent's record, conversation, turn summaries
and tool log. It holds no secret, no usage history and no other agent.

**Import Agents…** in a folder's menu sends the file to that folder's machine. Its agents
come back archived, to read and search. They are never run there, and bring no MCP servers.
An agent that the machine has already, or that it deleted (`erased.json`), is skipped.

The machine makes an export in its `Outgoing` folder and an import arrives in `Incoming`.
Each goes once it is read or imported, or after an hour untouched.

## Backups

See [Back up and restore a machine](../../how-to/back-up-and-restore.md).

- **A machine** backs up every day by default, and keeps the newest 3 (1 to 10). A backup
  holds each agent's record, conversation, turn summaries and tool log, and the usage and
  time history. It holds no sign-in, key or secret.
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
- **Machine providers' secrets are outside the store** (#2138). A copy of the store does not
  carry them.
- **A machine's backups are on its own disk by default** (#2139).
- **Not in a machine's backup:** settings, workflows, secrets, attachments, events and the
  runtimes' own session files. A folder's `.agents/` folder is in the folder, and so in its
  git repository if you commit it.
- **Writes that are not synced.** Appends to a machine's events, its records' logs and its turn summaries
  are not synced to disk one by one, so a power cut can lose the last lines.

## Related

- [Data flow](data-flow.md)
- [Security overview](security-overview.md)
- [Back up and restore a machine](../../how-to/back-up-and-restore.md)
- [The `~/.agents` folder](../../reference/agents-folder.md)
