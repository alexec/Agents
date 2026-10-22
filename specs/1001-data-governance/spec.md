# Feature Specification: Enterprise T8: data governance

**Feature Branch**: `agents/are-0-11-enterprise-18`

**Created**: 2026-10-22

**Status**: Draft. Slices (a) and (b) are built by the lane that wrote this spec. (c) and (d) are for other lanes.

**Milestone**: 0.11 Enterprise.

**Input**: Issue #1001, roadmap step T8 in `specs/research/733-team-and-enterprise.md`. It builds on T3 (audit: an actor on every host action, spec 736) and T5 (policy, `specs/998-org-policy/`). The compliance pack (the docs part of T8) is on `main` already (#2175, `docs/explanation/compliance/`). This spec is the four code parts.

## Why this feature exists

**An organisation's security team asks four questions.** Agents cannot answer them today.

1. **Do secrets end up on disk?** Yes. A token that an agent prints, or that a tool shows, goes into the transcript as it is. `daemon.log` can hold one too.
2. **When we delete an agent, is it gone?** Not fully. The runtime keeps its own copy of the conversation (for example Claude Code in `~/.claude/projects`). A backup can bring the agent back.
3. **Can we take our data out, and put it back?** Only by a whole-machine backup.
4. **Can we trust the audit log, and send it to our SIEM?** The entries are not tamper-evident, and they stay on the control plane.

## Decisions

Each of these is `Decided: <X>, because <Y>. Alex can overrule.`

| Question | Answer | Because |
|---|---|---|
| Where redaction happens | **In `agentsd`, when it writes a transcript line, and in its log writer.** The redacted line is also what the clients get. | Every transcript and every `daemon.log` line of Go goes through these two places. One place, one test. |
| Which tokens | **A fixed list of known token shapes** (GitHub, GitLab, Anthropic, OpenAI, AWS access keys, Google API keys, Slack, Stripe, npm, JWTs, private key blocks, `Bearer …`, the control plane's codes). A match becomes `[redacted:<kind>]`. | A shape has almost no false matches. A guess by entropy would cut hashes and IDs out of the conversation. |
| A switch to turn it off | **None.** Redaction is always on. | A token in a transcript is never useful. A switch is one more thing to audit. The policy (T5) can add shapes later. |
| A token split across two message chunks | **Not caught in slice (a).** Each transcript line is redacted alone. Slice (a2) holds back the end of a chunk to catch it. | Tool output, where most tokens appear, comes as one line. The seam needs a hold-back, which changes how text streams. |
| How erasure removes the runtime's copy | **The runtime deletes it, over ACP (`session/delete`), started as the agent was (same account).** When the runtime cannot, `agentsd` removes the files it knows: Claude's `<config>/projects/*/<id>.jsonl` and Codex's `<home>/sessions/**/rollout-*-<id>.jsonl`. | The runtime knows its own layout, also for added accounts and the relay home. The file list is a fallback for the two runtimes whose layout is known. |
| When erasure runs | **After the agent's folder is deleted, from a queue on disk** (`erasures.json`). One at a time. A queued erasure survives a restart. | Starting a runtime takes seconds. The retention sweep can delete hundreds of agents at once. |
| Backups that hold a deleted agent | **A restore skips it.** The machine keeps the IDs it erased (`erased.json`). The backups themselves age out (the newest 3 by default). | A backup archive is sealed and compressed. Rewriting it is slow and can break it. Skipping is enough to make sure the agent never comes back. |
| Server copies in the control plane's store | **The same rule: restore skips an erased ID.** A server's erased list is in its backups too. | The control plane holds no conversation outside the backups (data-and-retention.md). |
| Export format | **The backup archive format, for one agent or one project's agents.** Import brings them back archived, as a restore does. | One format, one reader, already tested. An imported agent is shown and never run, as a restored one is. |
| Hash chain | **On the control plane's audit entries, one chain for each copy of the control plane.** Each entry carries `seq` and `prev` (SHA-256 of the entry before). A seal for each day holds each chain's head. `agents-control audit verify` checks them. | Two copies write to one store at once. One chain for each writer needs no lock between copies. |
| Sinks | **Syslog (RFC 5424 over TCP or TLS) and HTTP (POST of JSON lines), set by an admin, from the control plane.** A bounded queue of 10,000 entries. When it is full, the oldest go and the next entry says how many. | The control plane already has every audit entry. A machine does not need to know about the SIEM. |

## Words

- **Token shape**: a pattern that only a secret of one kind matches, for example `ghp_` and 36 letters or digits.
- **Redacted**: a token shape replaced by `[redacted:<kind>]` before the line is written.
- **Erasure**: Delete, plus the runtime's own copy, plus never restoring the agent.
- **Erased list**: `erased.json` in the root: the IDs of agents this machine deleted.
- **Export**: a `.tar.gz` of one agent or of one project's agents, in the backup format.
- **Chain**: the audit entries of one copy of the control plane, each with the hash of the one before.
- **Sink**: a place outside the control plane that gets each audit entry: syslog or HTTP.

## User scenarios

### US1: Tokens do not go to disk (P1, slice a)

An agent runs `cat .env`. The file holds `GITHUB_TOKEN=ghp_…`. The tool call's output in the transcript says `GITHUB_TOKEN=[redacted:github]`. The Mac, the Remote and the web page show the redacted text. `daemon.log` has no token either.

**Acceptance:**

1. Given a transcript entry that holds a known token shape, when it is written, then the line on disk and the entry sent to the clients hold `[redacted:<kind>]` and no token.
2. Given a log line from `agentsd` that holds a known token shape, when it is written, then `daemon.log` holds `[redacted:<kind>]`.
3. Given text with no known token shape, then it is written unchanged.

### US2: Delete removes the runtime's copy (P1, slice b)

A person deletes an archived agent. Its folder goes, as today. Then the runtime's own copy of the conversation goes. A later restore of an older backup does not bring the agent back.

**Acceptance:**

1. Given an archived Claude agent with a session file, when it is deleted, then no file of that session stays in the Claude config folder.
2. Given a runtime that is not installed, or does not answer, then the files `agentsd` knows are removed, and the erasure is tried again at the next start, at most 3 times.
3. Given a backup that holds an agent that was deleted later, when it is restored, then that agent is skipped and the result says so.

### US3: Export and import (P2, slice c)

A person exports an agent or a project from its menu, on all three clients. They get a `.tar.gz`. On another machine they import it. The agents come back archived, to read and search.

### US4: An audit log that a SIEM can trust (P2, slice d)

An admin sets a syslog or HTTP sink in the Console. Each audit entry goes to it within seconds. `agents-control audit verify` says whether any entry was changed or removed.

## Requirements

- **FR-001**: `agentsd` MUST redact the known token shapes in each transcript line before it writes it, and send the redacted entry to the clients.
- **FR-002**: `agentsd` MUST redact the known token shapes in each line it writes to `daemon.log`.
- **FR-003**: Redaction MUST keep the line valid JSON, and MUST cost less than 50 µs for a 4 KB line.
- **FR-004**: Delete MUST queue the runtime's session for erasure, and erase it after the folder is gone.
- **FR-005**: The erasure queue MUST hold at most 1,000 entries; an entry is dropped after 3 tries or 7 days, with a log line.
- **FR-006**: The erased list MUST hold at most 10,000 IDs, oldest first out, and each ID for at most 400 days.
- **FR-007**: A restore MUST skip an agent on the erased list.
- **FR-008**: The `agent.deleted` event MUST say whether the runtime's copy was queued for erasure.
- **FR-009** (slice c): Export and import of an agent or a project, on the Mac, the Remote and the web page.
- **FR-010** (slice d): A hash chain on audit entries, a verify command, and syslog and HTTP sinks with a bounded queue.

## Success criteria

- **SC-001**: A test writes a transcript line and a log line with a GitHub token; neither file holds the token.
- **SC-002**: A test deletes a Claude agent whose session file exists in a scratch config folder; no file of it stays.
- **SC-003**: A test restores a backup with an erased agent; the agent does not come back.

## Out of scope

- Redaction in the runtimes' own files. They are the runtime's; erasure removes them.
- Text that is not a known token shape (a password in plain words).
- Redaction of what the Swift supervisor writes to `daemon.log` (start and stop lines, no tokens).
- Rewriting backup archives.
