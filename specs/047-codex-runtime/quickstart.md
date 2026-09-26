# Quickstart: proving Codex works

Everything runs on a scratch root (the run-app skill) and never touches the real app's daemon
or `~/.codex`, except in step 3, where Alex signs in once.

## 0. Prerequisites

- This branch, with main merged in (048 installer, 043 servers).
- `scripts/update-toolset.sh codex v24.21.0 1.13.1` has written
  `App/Resources/toolsets/codex/`. The lock holds `codex-darwin-arm64`, `-darwin-x64`,
  `-linux-arm64` and `-linux-x64`.
- For step 5: agents-bare up (test-servers skill), and an OpenAI API key.

## 1. Unit and fake-runtime tests

```sh
cd Packages/AgentsKit && swift test --filter 'Toolset|RuntimeInstaller|RuntimeDiscovery|ToolPolicy|Credential|Lending'
```

Expect:
- the policy is total over the catalog, including Codex;
- every `.toolset` runtime has a bundled manifest with a matching `runtimeID`;
- Codex is never found on the PATH;
- `CODEX_CONFIG` is in the launch environment, with the JSON in
  [contracts/runtime-launch.md](contracts/runtime-launch.md);
- `sk-ant-…` is Claude's and `sk-proj-…` is Codex's;
- a Codex lend sets `CODEX_API_KEY` and clears `OPENAI_API_KEY`;
- Claude's 043 and 048 tests are unchanged and green.

## 2. Install on the Mac (US1 #2–#3)

Launch a scratch root with no `tools/codex`. Settings ▸ Agents lists Codex as missing, with
**Install**. Press it:
- the row shows the install's steps (Node, then the adapter);
- when it finishes, `tools/codex/current/ok` exists and the row says ready.

Start a Codex agent during a second, forced-slow install (`file://` dist): it says Codex is
still being installed.

## 3. A real turn (US1, US2, US3): Alex signs in once

1. Start a Codex agent, signed out. It shows **Needs signing in**, and the sheet lists
   ChatGPT, device code and API key, in that order.
2. **Sign in with ChatGPT**: the browser opens, and after it the sheet says **Signed in and
   ready**. `codex login status` in Terminal (through the toolset's `codex`) agrees.
3. Prompt: "create hello.txt with one line, then run ls". The reply streams, the tool calls
   show, and the file shows in the changes.
4. Ask it to ask you a question first. A card appears on the Mac and on the phone, and the
   answer reaches Codex.
5. Ask it to lease `screen` and finish its turn. The lease and the outcome report arrive
   as they do for Claude.
6. Ask it "which tools do you have?". The answer lists no `spawn_agent`, memories, apps or
   goals, and does list the app's tools.
7. Stop it mid-turn, then resume. The history is there. The modes menu shows the three
   presets, and the model menu shows Codex's models.
8. Afterwards, `~/.codex/config.toml` has the same checksum as before the walk (SC-004).

`AGENTS_CODEX=1 swift test --filter CodexLive` repeats 3 and 5 unattended once signed in.

## 4. A new pin (D5, FR-003a)

With a Codex agent running on toolset A, rebuild with toolset B:
- the Codex row shows **Update**, and pressing it installs B and moves `current`, while the
  agent keeps running on A;
- A's folder is removed only once that agent has ended.

Claude's toolset behaves the same way.

## 5. On a server (US4)

1. Settings ▸ Runtime credentials ▸ Codex: paste the key. It says **Works**.
2. On agents-bare (nothing installed), start a Codex agent in a server project. The set-up
   checklist shows Codex's toolset installing. Ask it `uname -a`; the reply comes back.
3. `scripts/leak-check.sh` for the key on the box and in the Mac's logs finds nothing. The
   box has no `~/.codex/auth.json`, and the sign-in sheet there does not offer ChatGPT.
4. The Mac's Codex is still signed in with ChatGPT.

## 6. Docs

`scripts/docs-check.py` passes with the five pages in the spec's Docs section.
