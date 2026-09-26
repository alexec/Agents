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
