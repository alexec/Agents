# 047 walk: Codex on the Mac (scratch root /tmp/run-codex, 2026-09-25)

Everything here was driven over the scratch daemon's socket, with screenshots from the
scratch window. Alex's own app was not touched. The one real-home effect is his ChatGPT
sign-in in `~/.codex/auth.json`, which he agreed to.

| Step | Result |
|---|---|
| Set-up sheet lists Codex as **Not on this Mac** with **Install** | yes, `look/01-setup-before.png` |
| Install | 8 s, 540 MB, `codex-darwin-arm64` only, ticked with `…/tools/codex/current/bin/codex-acp` (`look/03-installed.png`) |
| Unsigned start | "Codex needs signing in: Authentication required", code -32007, with 3 methods |
| Sign in with ChatGPT | the browser opened, done in 10 s; `auth.json` written, account `ready`, `canLogOut` true |
| Real turn: list tools, write `hello.txt`, `ls`, finish | all 17 app tools seen; the file written; ended through `finish_turn` with `done`; 15 002 tokens, context 258 400, no cost |
| App tool approval | Codex's Guardian auto-review allowed `finish_turn`; no permission prompt reached the person |
| Question (`request_user_input`) | form card Red / Blue / None of the above + note; agent `waitingOnUser`; the answer "Blue" reached Codex, which wrote `blue` |
| Resume a finished agent | answered `hello.txt` from its history and ended with `done` |
| Menus | Mode (Ask for approval / Approve for me / Full access), Collaboration mode (Default / Plan), Model (6 Luna, 5.6 Terra, 5.6 Luna, 5.5), Reasoning effort; slash commands `/plan /mcp /skills /status /review /review-branch /review-commit /compact` |
| Tool scoping (`scripts/runtime-tools.sh codex`) | 5 of 5 removed, `request_user_input` kept, 6 `collaboration.*` residue named, 0 unexplained |
| SC-004 | `~/.codex/config.toml` absent before and after |

Not yet seen: the question card drawn on screen (the set-up sheet was over it in
`look/04-question.png`), stopping mid-turn, a picture attachment, the phone.
