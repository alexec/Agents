# Quickstart: proving OpenCode

Every walk runs on a scratch root (the run-app skill) with a scratch `HOME`/`XDG_*` for OpenCode.
Never the real home, and never OpenCode's install script.

1. **Install from the set-up page** (Story 1, AS-2/3). Start a scratch app with no
   `tools/opencode`. The sheet comes back listing OpenCode. Press **Install**: the row shows
   downloading → checking → done, with ~46 MB named. `tools/opencode/current/ok` exists.
2. **The name trap** (Story 2). Put `scripts/fake-acp-runtime.py` first on the search path
   as `opencode`, with a marker file. Before the install the row reads **Not on this Mac**.
   After it, start an agent: it works, and the marker was never written. The sign-in sheet's
   command is `<root>/tools/opencode/current/bin/opencode auth login`.
3. **A first turn, signed out** (R2). Start an OpenCode agent with the prompt "create hello.txt
   and run ls". Check four things:
   - a permission card for the edit and for `ls`;
   - the file in Changes;
   - the model menu shows `OpenCode Zen/…`, and the modes are build and plan;
   - the meter shows tokens, and no "$0".
4. **The app's tools**. Ask it to list its tools: `agents_*` are there, and `task` and
   `todowrite` are not. Ask it to finish with a report and to ask a question: an outcome and a
   question card arrive.
5. **Resume**. Stop the agent, quit the scratch app, relaunch and resume: the conversation
   continues.
6. **Sign in** (Story 3). Pick a model id of an unsigned provider through the socket: the
   sentence names the provider, and the sheet offers Open Terminal / Copy.
7. **Always approve** (061). Set OpenCode to Always approve: the next edit brings no card.
8. **Handshake** — `AGENTS_OPENCODE_SHIM=<root>/tools/opencode/current/bin/opencode
   scripts/acp-handshake.sh` lists every capability with an action. Re-run it for all runtimes
   after the `_meta["terminal-auth"]` change.
9. **Servers** (Story 5, test-servers skill, `agents-devbox`). Add the server. Start an
   OpenCode agent in a server project: the checklist shows the install. Give the scratch Mac
   home an `auth.json` holding a test key, then:
   - the lent provider's models appear;
   - `grep -r <key> /` on the box finds nothing afterwards;
   - an "own sign-in only" server gets nothing lent.
10. **Untouched home** (SC-005). Hash the scratch home's `~/.config/opencode` and `auth.json`
    before and after a day's walks: the app changed nothing.
