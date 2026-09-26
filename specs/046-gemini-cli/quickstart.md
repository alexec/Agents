# Quickstart: proving Gemini works

Prerequisites: nothing installed for Gemini (the set-up page installs it); a Gemini API key (AI Studio) for the live steps, kept in
the scratch root's environment only, never in the real app's.

## 1. Handshake (no key)

```sh
scripts/acp-handshake.sh gemini   # once Phase 1 adds gemini to its RUNTIMES
```

Expect `agentInfo.version` = the pinned version, `loadSession: true`, four auth methods, and
`session/new` refused with `-32000`.

## 2. Unit and fake-runtime tests

```sh
cd Packages/AgentsKit && swift test --filter 'ToolPolicy|RuntimeCatalog|PolicyFiles|PromptResult|Credential'
```

The catalog-totality test lists five runtimes; the policy file test writes
`gemini-policy.toml` and passes `--policy <path>`; the quota test maps `_meta.quota` to tokens
with no cost.

## 3. The set-up page (scratch root)

Launch a scratch copy with the run-app skill. Expect the **Install your agents** sheet listing
Gemini as **Not on this Mac** with **Install**, even with a `gemini` on the PATH. Press it:
progress steps on the row, then a tick with `<root>/tools/gemini/current/bin/gemini`. Nothing
is written outside `<root>`.

## 3a. A real turn on the Mac (scratch root)

Use the run-app skill with `GEMINI_API_KEY` in the scratch launch environment. Start a Gemini
agent in a scratch project and ask: "create hello.txt with one line, run ls, then finish".
Expect: streamed reply, a permission ask for the shell command, `hello.txt` in changes,
tokens on the turn and no cost, the turn ending through the app's outcome report. Stop mid-turn
once; resume once and see history.

Ask it "list your tools": `invoke_agent` and `tracker_*` absent (or refused with the app's
sentence), the app's tools present.

## 4. Nothing of the person's touched

```sh
shasum ~/.gemini/settings.json ~/.gemini/trustedFolders.json 2>/dev/null   # before
# … a day of Gemini agents …
shasum ~/.gemini/settings.json ~/.gemini/trustedFolders.json 2>/dev/null   # after: identical
```

## 5. A bare server

With the test-servers skill on `agents-bare` (127.0.0.1:2223): paste the key in scratch
Settings ▸ Runtime credentials ▸ Gemini (expect **Works**), start a Gemini agent in a server
project, ask for `uname -a`. Expect the install in the checklist, then the reply within
5 minutes. Then:

```sh
scripts/leak-check.sh agents-bare "$GEMINI_API_KEY"   # finds nothing on disk or in logs
```
