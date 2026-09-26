# 046 walk notes

## 2026-09-25 — set-up row and install, scratch root /tmp/run-046 (build a643eb6)

- `runtimes/list` on a fresh root: Claude, Grok, Copilot, Cursor found where they are on this
  Mac; **Gemini `missing`, looked in `/tmp/run-046/tools/gemini/current/bin`, with an install
  recipe** — the PATH is not searched (usesAppCopyOnly).
- `runtimes/install gemini` over the socket: `installing` → "Downloading Node.js v24.21.0" →
  "Installing Gemini" → `available` at `/tmp/run-046/tools/gemini/current/bin/gemini`, about 15 s.
  Only `ab59d3a4f9e41eb5` and `current` in `tools/gemini/`.
- The shim is `bin/gemini`, passes `"$@"`, runs Node v24.21.0 and Gemini 0.61.0;
  `acp-handshake.sh` against it matches research R2.
- **Not seen**: the sheet itself. This session has lost screen-recording permission
  (`CGPreflightScreenCaptureAccess` false), so no screenshot; the accessibility read was
  refused. The look gate (T026) is Alex's eyes on the start-up sheet.

## 2026-09-25 — live Gemini agents on this Mac, scratch root /tmp/run-046 (build 76b6eaf)

- Key lent over the socket (`credentials/lend`, runtime `gemini`), as the window does on connect.
- Agent 1: "create hello.txt … run ls … finish_turn". Shell permission asked and answered,
  `hello.txt` written, ended through the app's `finish_turn` (workReported: done), usage
  recorded 116,941 in / 300 out, no cost. The key is in no file under the root.
- **Bug found**: Gemini's `write_file` reads first through the app's `fs/readTextFile`; the
  app said "There is nothing readable at …" for a new file, which Gemini takes as a failure,
  so it fell back to the shell. Fixed: a missing file is "Resource not found: <path>", the
  protocol's words, which Gemini reads as ENOENT (FileServiceTests).
- Agent 2 (to prove the fix) was refused by Google: JSON-RPC `429` "You have exhausted your
  daily quota on this model." — the free tier's daily quota spent (R9 measured). The app
  said "Gemini stopped answering" and called the process dead. Fixed: a provider's limit is
  said in its own words and ends the turn (UsageLimitTests). The write_file fix is proven by
  test only until the quota resets.

## 2026-09-25 — Gemini on a bare Linux server (agents-bare, 127.0.0.1:2223, real ssh)

`AGENTS_BARE=1 swift test --filter aBareServerGetsGeminiLendsItsKeyAndSaysARefusalIsOne`, with
the Linux agentsd built from this branch:
- Gemini's toolset (Node v24.21.0 + @google/gemini-cli 0.61.0) installed from nothing, `npm ci
  --ignore-scripts` with no compiler (T008), server connected in **12.3 s**.
- A Gemini start asked for the key once, was lent a made-up `AIza…` key, started; Google
  refused it and the agent said "Gemini refused the key in Settings. Replace it in Settings ▸
  Servers."
- `grep` for the key over the server's `$HOME` and `/tmp`: nothing (FR-016).
- Claude's case (`aBareServerGetsClaudeLendsOnDemandAndSaysARefusalIsOne`) still passes.
- A real turn on the server waits for the quota to reset on Alex's free key.

Also found: main's Linux agentsd no longer built (048/047's Mac installer imports CryptoKit and
URLSession). Guarded: a server's agentsd hashes and downloads nothing of its own (043).

## 2026-09-25 (evening) — live walk on gemini-3-flash-preview, scratch root /tmp/run-046

Three real bugs found and fixed, each proven by a test that reproduces what Gemini did:

1. **No model or mode menu for Gemini** (`b11d931`). Gemini sends `models` and `modes`, not
   `configOptions`, and sets them with `session/set_model` / `session/set_mode`. The app showed
   neither menu and dropped a model chosen at the start, so every turn ran on **Auto**, which
   picked a Pro model and spent the free tier's daily quota. Now the same two menus, set the
   older way. Live: the agent ran on gemini-3-flash-preview as chosen.
2. **New files could not be written through the app** (`b153ad4`). Gemini's `write_file` counts
   only an error with code `ENOENT` as "a new file", and a JSON-RPC error over ACP can never
   carry one, so "Resource not found" was not enough. Gemini now reads files itself and still
   writes through the app. Live: `notes.md` created in one write, with the permission ask and
   diff, no shell, no retries (agent D12830DA).
3. **Picking a Gemini conversation back up lost it** (`3c644dd`). Gemini answers `session/load`
   with -32000 "Authentication required" until `authenticate` is called, key or not. Reproduced
   by hand against the installed Gemini: `authenticate gemini-api-key` then `session/load` loads
   it. The session now signs in first. Proven by test (GeminiContinueTests); the live re-check was
   stopped by the quota.

Also seen: a quota refusal now reads "Gemini hit its provider's limit: You have exhausted your
daily quota on this model." Gemini, told a one-off task was done, chose `afterwards: archive`
on `finish_turn` (main's new option), so those agents archived themselves — as the option's
description allows. Gemini keeps its own chat history and project names in `~/.gemini/tmp` and
`~/.gemini/projects.json` of whoever runs the daemon (the real home, for a scratch daemon); the
app writes none of it, and `~/.gemini/settings.json` was never created.

## 2026-09-26 — lease and wait (T034), scratch root /tmp/run-046 (build 8f38e16, main)

- gemini-3-flash-preview was still refused by Google ("You have exhausted your daily quota on
  this model.", said in those words); gemini-3.5-flash-lite, from the same model menu, was not.
- One Gemini agent, told to lease `gemini-walk`, wait for `custom.gemini_go`, release, and say
  the event's message: `lease_resource` → "Leased gemini-walk until 23:27." The events page's
  waiting list then showed it "◷ Waiting for custom.gemini_go · until 23:22", cancellable.
- `custom.gemini_go` raised with the message `pineapple-42`: the event's consequence was
  "woke" that agent. It released the lease ("Released gemini-walk."; the lease was gone from
  the snapshot), replied `pineapple-42` and ended through `finish_turn` (done). Usage was
  recorded as 71,416 tokens in and 187 out.
- The key was in no file under the root.
