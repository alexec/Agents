# Feature Specification: Claude on Servers Through This Mac's Sign-in

**Feature Branch**: `agents/claude-sign-in-relay`

**Created**: 2026-09-26

**Status**: Draft

**Input**: User description: "Claude on servers uses this Mac's own Claude sign-in through the
047-style relay (research in specs/056-claude-sign-in-relay/research.md). No pasted-token
fallback: the Settings ▸ Servers Claude token is removed."

## Why this feature exists

Today a server's Claude needs a token that the person makes with `claude setup-token` on the
Mac and pastes into **Settings ▸ Servers** (043). It's one more step before a server is
useful, a secret to keep track of, and a second way of signing Claude in beside the one the
person already uses on the Mac.

047 removed the same step for Codex. A server's Codex sends its requests back through the
Mac, and the Mac adds its own ChatGPT sign-in. The sign-in never leaves the Mac. The 056
spike (research R1) proved the same works for Claude. A real turn ran on agents-devbox with
only a placeholder token, every request went through a relay on the Mac, and no part of the
real sign-in was found on the box.

**This feature makes a server's Claude sign in the way this Mac's Claude does**, through the
Mac. The pasted token goes away entirely.

## Defaults taken

Alex settled D1 and D2, and confirmed D3–D7, on 2026-09-26. Each is marked *(default Dn)*
where it is used.

- **D1. A server's Claude uses this Mac's own Claude sign-in, relayed.** It is the same
  sign-in Claude uses on this Mac, the one `claude` keeps in this Mac's Keychain. Nothing of
  it is copied to, written on or sent to a server. *(Settled by Alex.)*
- **D2. No pasted token, not even as a fallback.** Claude's row under **Runtime
  credentials** in Settings, the "needs a token" sheet and the token check all go. A token
  saved by an earlier version is deleted from the Keychain. *(Settled by Alex.)*
- **D3. Only a Claude account sign-in is relayed.** The relay lends the sign-in `claude`
  made with the person's Claude account (Pro, Max, Team or Enterprise). If Claude on this
  Mac is signed in some other way (an API key in the environment, a cloud provider), servers
  are not given it. The server's Claude then needs its own sign-in, as it does when this Mac
  is not signed in.
- **D4. The relay keeps the sign-in fresh without signing the Mac out.** The Mac's Claude
  renews its own sign-in when it's used. If nobody uses it and a server's request is
  refused because the sign-in expired, the relay has the Mac's own Claude renew it, once,
  and uses the result. First it re-reads what Claude has saved, in case Claude already
  renewed it. The app never renews or writes the sign-in itself, so it and the Mac's Claude
  can never both spend the same renewal (plan research R6). If the renewal
  fails, the turn ends saying so. The relay never discards the Mac's sign-in.
- **D5. Only the person's own agents on a server can use it.** The relay answers only
  requests from the server account the Mac connects as, as 047's gate does for Codex. Other
  accounts on the same server are refused.
- **D6. "Use this server's own sign-in only" still wins.** A server marked this way (043)
  gets no relay for Claude, as it already gets none for Codex. The server's own Claude
  sign-in is used.
- **D7. Otherwise the Mac's sign-in beats a server's own.** On a server that is not marked,
  the relayed sign-in is used even if Claude is signed in on the server. That matches how
  the lent token behaved before (043).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start Claude on a server with nothing to set up (Priority: P1)

The person's Mac has Claude signed in with their Claude account. They add a server and
start a Claude agent in a project on it. It answers. They never opened Terminal, never made
a token and never pasted anything. Turns on the server count against the same Claude plan
as turns on the Mac.

**Why this priority**: This is the feature. Without it, servers need a pasted token, and
D2 has removed that.

**Independent Test**: On a Mac whose Claude is signed in with a Claude account, add
agents-bare (no Claude, no sign-in) with no token anywhere in Settings. Start a Claude agent
in a project there and ask it to run `uname -a`. It answers with the server's kernel.
Search the server's disk and the Mac's logs: no part of the Mac's sign-in appears in
either.

**Acceptance Scenarios**:

1. **Given** Claude on this Mac is signed in with a Claude account, **When** a server
   connects, **Then** the Add a server checklist installs Claude there without asking for
   anything, and the runtime menu for that server says Claude **signs in through this Mac**.
2. **Given** that server, **When** the person starts a Claude agent there, **Then** it
   answers, and every request it makes to Anthropic goes through this Mac.
3. **Given** several servers connected at once, **When** Claude agents run on each,
   **Then** they all use the same sign-in on this Mac, and none of them affects the others
   or the Mac's own agents.
4. **Given** a Claude agent on a server that starts helpers of its own (028), **When**
   those helpers run, **Then** they use the relayed sign-in too.
5. **Given** a turn on a server, **When** it ends, **Then** its usage shows the same way as
   a Claude turn on this Mac under a plan: tokens, and a cost only where Claude reports one.
6. **Given** a Claude agent started on a server from the iPhone or iPad Remote, **When** it
   runs, **Then** it uses the relayed sign-in exactly as one started from the Mac does.

---

### User Story 2 - The token is gone (Priority: P1)

A person who had pasted a Claude token before this version opens **Settings ▸ Servers**.
There is no Claude token row. The page says a server's Claude uses this Mac's sign-in. The
old token is no longer in the Keychain, and no screen anywhere asks for one.

**Why this priority**: D2 has settled it, and a leftover field or sheet that asks for a
token no longer used would mislead.

**Independent Test**: On a scratch root whose Keychain holds a Claude token saved by the
previous version, start the new app. Settings ▸ Servers has no Claude token row, and the
Keychain no longer holds the token. Start Claude on a server while this Mac is signed out
of Claude: no token sheet appears (User Story 4 says what does).

**Acceptance Scenarios**:

1. **Given** Settings ▸ Servers, **When** the person opens it, **Then** **Runtime
   credentials** has no row for Claude. Gemini's row and anything else that is still lent
   stays as it is. The page says, in one line, that Claude and Codex on a server use this
   Mac's own sign-ins.
2. **Given** a Claude token saved by an earlier version, **When** the new version starts,
   **Then** the token is removed from the Keychain, other runtimes' saved credentials are
   kept, and nothing is shown about it.
3. **Given** any server state, **When** a Claude agent cannot start, **Then** the app never
   shows the "needs a token" sheet, never says "Claude refused the token in Settings", and
   never points to `claude setup-token`.
4. **Given** the server checklist, **When** it runs, **Then** **Install Claude** runs
   whenever this Mac can lend its sign-in, instead of only when a token was saved.

---

### User Story 3 - Long runs don't sign anyone out (Priority: P2)

The person starts a long Claude job on a server and doesn't touch Claude on the Mac all
afternoon. Hours later the Mac's sign-in has expired and the server's next request is
refused. The relay renews it once and the job carries on. That evening the person opens
Claude on the Mac: it is still signed in.

**Why this priority**: Without it, a server's Claude stops after a few hours of the Mac
being idle. But the risk of getting it wrong (signing the Mac out) is worse than stopping,
so it comes after the basic path works.

**Independent Test**: With the relay in place, make the Mac's access token expired while
its renewal is still good, then run a turn on a server. It succeeds, the saved sign-in on
the Mac is the renewed one, and `claude` on the Mac still works without signing in again.
Then run a renewal on the Mac and a server request at the same moment: both end signed in.

**Acceptance Scenarios**:

1. **Given** the Mac's sign-in has expired but can still be renewed, **When** a server's
   request is refused as expired, **Then** the relay has the Mac's Claude renew it once, sends
   the request again with the renewed sign-in, and the turn goes on *(default D4)*.
2. **Given** Claude on the Mac renewed the sign-in a moment ago, **When** the relay goes to
   renew, **Then** it finds the renewed sign-in, uses it, and does not renew again.
3. **Given** the renewal itself is refused (the person signed out, or the sign-in was
   revoked), **When** a server's request needs it, **Then** the turn ends with a sentence
   saying Claude on this Mac needs signing in again, and offers the sign-in sheet (053).
   Nothing on the Mac is discarded.

---

### User Story 4 - When the Mac can't lend it (Priority: P2)

The Mac isn't signed in to Claude, or the server is marked to use its own sign-in, or the
Mac drops off the network. Each case says what happened in one sentence and what to do. None
ends in an endless wait or "Claude stopped answering".

**Why this priority**: With no token to fall back on (D2), these cases are now the only
thing the person sees when the relay can't be used.

**Independent Test**: Sign Claude out on the Mac and start Claude on a server: it ends with
the sentence and the sign-in sheet. Mark the server "own sign-in only" with Claude signed in
there: it runs, and nothing goes through the relay. Cut the Mac's connection mid-turn: the
turn ends saying the Mac went offline.

**Acceptance Scenarios**:

1. **Given** Claude on this Mac is not signed in, or is signed in some way the relay does
   not lend *(default D3)*, **When** the person starts Claude on a server not marked "own
   sign-in only" and with no Claude sign-in of its own, **Then** it ends before starting with "Claude on this Mac isn't signed in
   with a Claude account", offering the sign-in sheet and the "own sign-in only" setting.
2. **Given** a server marked "own sign-in only", **When** Claude starts there, **Then**
   nothing is relayed, and the server's own sign-in is used. If it has none, it ends with
   Claude's own sentence for being signed out *(default D6)*.
3. **Given** a server that is not marked but has Claude signed in on it, **When** Claude
   starts there, **Then** the Mac's sign-in is used *(default D7)*.
4. **Given** a turn in flight on a server, **When** the Mac's connection to it drops,
   **Then** the turn ends with 037's offline sentence, and resumes as other server turns do
   once it's back.
5. **Given** the Claude plan has reached its usage limit, **When** a server's request is
   refused for it, **Then** the turn ends saying so, with the reset time when Claude gives
   one. The Mac and its servers share that one plan.

---

### User Story 5 - Nobody else on the server can use it (Priority: P2)

The server is shared. Another account on it finds the forwarded port and tries to send
requests through it. They are refused, and the refusal is in the relay's log.

**Why this priority**: The relay spends the person's plan. On a shared server, an open port
would let anyone spend it.

**Independent Test**: On agents-devbox, as a second account, send a request to the relay's
port on the server. It is refused. As the person's own account, a Claude turn still works.

**Acceptance Scenarios**:

1. **Given** a request from another account on the server, **When** it reaches the relay,
   **Then** it is refused, and the relay's log says it was refused and why *(default D5)*.
2. **Given** the relay's log, **When** anyone reads it, **Then** it holds only what was
   asked and how it was answered (a method, a path, a status), never a header, a body or any
   part of a sign-in.

---

### Edge Cases

- **The Mac's Claude is updated and changes where it keeps its sign-in.** The relay finds no
  sign-in it can read and behaves as if the Mac were signed out (User Story 4). It doesn't
  guess, and it never writes a sign-in of its own.
- **The Keychain asks before letting the app read the sign-in.** If macOS shows a prompt and
  the person refuses, that counts as not signed in (User Story 4), and the sentence says the
  app couldn't read Claude's sign-in.
- **Two servers' requests both find the sign-in expired at once.** One renewal happens, and
  both requests use its result (D4).
- **The person signs Claude out on the Mac mid-turn.** The server's next request is refused.
  The turn ends as in User Story 3, scenario 3.
- **A server's agents run while the Mac sleeps.** 024 keeps the Mac awake while a turn is in
  flight, and server turns count. A Mac put to sleep by hand ends the turn as offline.
- **The server's environment already has `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`.**
  On a server that is not marked "own sign-in only", the relay's settings replace them for
  that run, as the lent token did (043 D1).
- **A server was set up with a lent token by an earlier version.** Nothing of the token was
  ever written there, so there is nothing to clean up. The next run uses the relay.
- **Fast mode or other plan-bound features.** The server's Claude gets whatever the Mac's
  plan allows, since the requests are the Mac's.

## Requirements *(mandatory)*

### Functional Requirements

**Signing in on a server**

- **FR-001**: A Claude agent on a server that is not marked "own sign-in only" MUST sign in
  with this Mac's own Claude account sign-in, relayed through the Mac *(D1)*.
- **FR-002**: No part of the Mac's sign-in (access, renewal or any other secret) MUST be
  copied, lent, written or sent to a server, or written to the Mac's logs or the app's
  folder. The server is given only a placeholder with no secret in it.
- **FR-003**: The relay MUST be shared by every connected server and every Claude agent on
  them, including helpers and agents started from the Remote.
- **FR-004**: The relay MUST answer only requests from the server account the Mac connects
  as. Every other request MUST be refused and logged as refused *(D5)*.
- **FR-005**: The relay MUST pick up a renewal by Claude on the Mac before it uses an expired
  sign-in, and at the latest on the next refused request, so a renewal made on the Mac is
  never lost.
- **FR-006**: When a request is refused because the sign-in expired, the relay MUST re-read
  the saved sign-in. If it's still expired, the relay MUST have the Mac's own Claude renew it
  at most once, then send the request again. The app MUST NOT renew, write or discard the
  Mac's sign-in itself *(D4)*.
- **FR-007**: A server marked "own sign-in only" MUST get no relay for Claude, and its own
  sign-in MUST be used *(D6)*. On any other server the relayed sign-in MUST win over one on
  the server *(D7)*.
- **FR-008**: Claude MUST be installed on a server as it connects whenever this Mac can lend
  its sign-in. Whether a token is saved no longer matters, because there is none.

**The token removed**

- **FR-009**: Settings MUST NOT offer a Claude token or Claude API key for servers.
  **Runtime credentials** MUST keep the rows for other runtimes that still take a credential.
- **FR-010**: On first start, the app MUST delete a Claude credential saved by an earlier
  version from the Keychain, and MUST keep every other runtime's saved credential.
- **FR-011**: No screen, sentence or sheet MUST ask for a Claude token, check one, say one
  was refused, or point to `claude setup-token`.

**What the person is told**

- **FR-012**: The runtime menu for a server MUST say Claude **signs in through this
  Mac** when the relay is available, **its own sign-in** on a server marked "own sign-in
  only", and **needs this Mac signed in to it** otherwise (contracts/ui.md).
- **FR-013**: A Claude agent that can't start or can't go on because of the sign-in MUST end
  with one sentence naming the cause: this Mac not signed in with a Claude account, the
  sign-in couldn't be read, the renewal was refused, a plan limit, or the Mac went offline.
  Where signing in again would help, it MUST offer the sign-in sheet (053). It MUST NOT wait
  forever or say "stopped answering".
- **FR-014**: The relay's log MUST record only method, path, status and refusals. It MUST
  never record a header, a body or any part of a sign-in.

### Key Entities

- **This Mac's Claude sign-in**: the one `claude` keeps in the Mac's Keychain for the
  person's Claude account: an access part that expires within hours, and a renewal part
  that replaces itself when used. The relay reads it, and writes it only after a successful
  renewal.
- **Claude's relay**: the Mac's end, shared by all servers. It adds the Mac's current
  sign-in to each request from a server's Claude and sends it on to Anthropic. It sits
  beside Codex's relay (047) and follows the same rules.
- **The server's gate**: the server's end, which admits only the connecting account's
  processes.
- **Placeholder sign-in**: what a server's Claude is started with. It looks like a sign-in
  but holds no secret, and works only through the relay.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: From a bare Linux server, a person whose Mac is signed in to Claude gets a
  Claude agent's first reply within 5 minutes of adding the server, having typed no command,
  made no token and pasted nothing.
- **SC-002**: After that, a search of the server's disk and the Mac's logs and app folder
  finds no part of the Mac's sign-in.
- **SC-003**: A Claude job on a server keeps running across the Mac's sign-in expiring at
  least once, with Claude on the Mac idle throughout, and afterwards Claude on the Mac is
  still signed in without asking.
- **SC-004**: 100% of requests to the relay from a second account on the server are refused.
- **SC-005**: No screen in the app mentions a Claude token, and an upgraded Mac's Keychain
  holds no Claude token from the app.
- **SC-006**: Each failure in User Story 4 ends a turn within 10 seconds with its sentence,
  never an endless wait.

## Docs *(mandatory)*

- `docs/how-to/add-a-linux-server.md` — change: drop **Give Claude a token**. Claude, like
  Codex, uses this Mac's sign-in through the Mac, and needs this Mac signed in to Claude.
  Update the checklist's **Install Claude** line, the runtime menu wording, and the "own
  sign-in only" section. Replace the "needs a token" and "refused the token" troubleshooting
  entries with the new sentences.
- `docs/reference/settings.md` — change: Settings ▸ Servers' **Runtime credentials** no
  longer lists Claude.
- `docs/reference/runtimes.md` — change: Claude on servers uses this Mac's sign-in, not a
  token from Settings.
- `.agents/skills/test-servers/SKILL.md`: change. A Claude turn on a server needs this Mac
  signed in, not a pasted token.
- `docs/how-to/sign-a-runtime-in.md` — change: signing Claude in on the Mac is also what
  signs it in on servers.

## Assumptions

- The relay works over plain HTTP on the server's loopback, inside the ssh connection, as
  the spike showed (R1, finding 4). Whether it shares TLS and certificates with Codex's relay
  is a plan decision.
- The app can read the Mac's sign-in from the Keychain without a prompt, as the spike did
  (R1, finding 5), and can write back a renewal the same way. The plan confirms the write,
  on a scratch Keychain item and never on Alex's sign-in, before relying on it.
- Renewing the sign-in is the same exchange Claude makes itself. The plan measures it
  against a throwaway account's sign-in, never Alex's, since a wrong guess spends the renewal.
- The app runs Claude on servers through its ACP adapter. The adapter passes the relay's
  settings to Claude as it already passes the lent token. The plan checks this, which the
  spike did not (R2).
- Checking Anthropic's terms for relaying a subscription sign-in to the person's own
  servers is Alex's, and must be done before this merges.
- This builds on 043 (server toolsets, "own sign-in only", lending), 047 (the relay, the
  gate, the Codex key removed in f10cd50) and 053 (the sign-in sheet on an auth failure),
  all merged. 052 (quota fallback) now has to count server Claude turns against the Mac's
  plan, and whichever of 052 and this merges second adapts.
