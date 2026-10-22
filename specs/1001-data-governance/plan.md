# Implementation Plan: Enterprise T8, data governance

**Spec**: `spec.md` · **Issue**: #1001 · **Milestone**: 0.11 Enterprise

## Summary

Four parts, cut into slices by area (`.agents/areas`). Each slice is one pull request. The lane that wrote this spec builds (a1) and (b1). Other lanes build the rest.

| Slice | What | Areas | Order |
|---|---|---|---|
| **a1** | `redact` package; transcript lines and `daemon.log` | hosts | first |
| a2 | The seam between two message chunks: hold back a trailing run of token characters (at most 256 bytes) until the next chunk or the end of the message | hosts | after a1 |
| a3 | The control plane's log uses the same shapes (`controlplane/log.go` `Redact` calls `redact.Text`) | control-plane | after a1 |
| **b1** | Erasure queue, runtime `session/delete`, Claude and Codex files, erased list, restore skips it | hosts | after a1 |
| c1 | `agents/export`, `agents/import` (wire + daemon), backup format for one agent or one project | hosts, wire (`-`) | after b1 |
| c2 | Export and Import in the agent and project menus on the Mac, the Remote and the web page | sidebar, projects | after c1 |
| d1 | Hash chain on audit entries, a seal for each day, `agents-control audit verify` | reports | any time |
| d2 | Syslog and HTTP sinks with a bounded queue; settings in `control.json` | reports, control-plane | after d1 |
| d3 | Console ▸ Audit ▸ Sinks on the web page | reports (Console) | after d2 |

## Technical context

- **Language**: Go 1.x, `Go/internal/agentsd`. No new module dependencies.
- **Tests**: `go test ./internal/agentsd/...` filtered by `scripts/select-test-suites.sh`.
- **Constraints**: every store has a bound (robustness first). Redaction runs on every transcript line, so it is one pass of a few compiled regular expressions, and a cheap check first (a line with none of the prefixes is not scanned).

## Design

### a1: redaction

- **`Go/internal/agentsd/redact`**: `Text(s string) string`, `Bytes(b []byte) ([]byte, bool)`. A table of `{kind, regexp}`. Before the expressions run, a byte search for the fixed prefixes (`ghp_`, `sk-`, `AKIA`, `eyJ`, `-----BEGIN`, …) skips lines that hold none.
- **Transcripts**: `store.AppendMany` redacts each marshalled line. When a line changed, it decodes the line back into the caller's entry, so `record` sends the redacted entry to the clients.
- **`daemon.log`**: `cmd/agentsd`'s `logLine` writer redacts each line before it is stamped.
- **Not covered**: what a runtime writes to standard error, which goes to the file descriptor directly (panics). It has no tokens of ours.

### b1: erasure

- **`erasures.json`** in the root: `[{agentID, runtimeID, sessionID, accountID, cwd, queuedAt, tries}]`, at most 1,000, written atomically.
- **`deleteArchived`** adds an entry when the agent had a runtime session, then wakes the eraser. The `agent.deleted` event gets `runtimeCopy: queued`.
- **The eraser** (one goroutine, `safe.Go`): for each entry, start the runtime as the agent was (`launchAs` with its account), 60 s at most. When it offers `session/delete`, call it. Then, for Claude and Codex, remove the known files in the home that the launch named (`CLAUDE_CONFIG_DIR` or `~/.claude`; `CODEX_HOME` or `~/.codex`). Success, or a third failure, or 7 days, removes the entry.
- **`erased.json`**: `{id: erasedAt}`, at most 10,000 and 400 days. `restoreAgent` skips an ID in it. Backups carry the file, so a server's list survives a new machine.

### c, d

See the table. Their lanes write their own plan sections.

## Docs

Each slice updates `docs/explanation/compliance/` (index, data-and-retention, security-overview) to say what is built.
