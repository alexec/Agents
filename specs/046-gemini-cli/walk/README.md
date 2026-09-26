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
