# Quickstart: walk the team tier on a scratch set-up

Use the `run-app` and `test-servers` skills. Do not use the real control plane or real agent records.

1. **One person, no change (US1).**
   - Start a scratch control plane from a copy of a v0.7 store. It has two clients and two hosts.
   - Open the window. The same machines and agents are there, and no sign-in sheet shows.
   - Settings has the rail groups This device / You / Control plane.
2. **A second person (US2).**
   - Turn on Google with a test issuer. The Go tests use a local JWKS server and a client id the test build trusts.
   - Invite `sam@example.test`. On a second scratch client, sign in as Sam and accept.
   - `people/list` shows two people. Sam's `hosts/list` is empty.
3. **A machine joins (US3).**
   - Start `agentsd` in the `agents-devbox` container with `--control <address> --person sam`. It prints a code.
   - Approve it on Sam's client. Sam's `hosts/list` has it, and Alex's does not.
   - From Alex's client, `agents/start` on it gives `notFound`.
4. **Secrets follow (US4).**
   - As Sam, set an MCP server with a secret. Start a workspace from a provider in Sam's group.
   - Within 30 s the server is in that machine's `~/.agents`, and its secret in `~/.agents-secrets`.
   - `grep -r` for the secret under the store finds nothing.
5. **A bot (US6).**
   - Make `review-bot`, approve two machines for it, and add a workflow with `runs-on: [review-bot]` and an event trigger.
   - Send one event. Exactly one run claim is in `runs/`, and one session runs.
   - That session's tool list has no `ask_form`.
6. **Remove Sam (US5).**
   - The preview lists Sam's started machine and its branch that is not pushed. Confirm.
   - Sam's client is closed with `removed` within 5 s, and the workspace is deleted.
7. **Close everything** with the run-app skill's "When you are done" steps.
