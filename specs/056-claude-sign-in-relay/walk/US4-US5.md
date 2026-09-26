# US4 and US5 walks (2026-09-26)

Proven without the window: `DevboxRelayLiveTests` (`AGENTS_DEVBOX=1`) uses the same
`ServerConnection` and `MacSignInRelay` the window uses, with this Mac's real Claude sign-in
(read only), against agents-devbox, which has Claude signed in on its own.

**US5, nobody else on the server can use it (D5, SC-004).** After a relayed turn, `curl`
run as a second account (`other`, uid 1001, made with `docker exec -u root agents-devbox
useradd -m other`) against the gate's port got no HTTP answer (`000`). The Mac's relay log
gained no line. The server's log said:

    relay gate: refused a connection from port 34238 (uid 1001, not uid 1000)

**US4, when the Mac can't lend it:**
- **Not marked, server signed in on its own (D7).** The relayed turn went through this
  Mac (`POST /v1/messages -> 200` in the relay's log), although the devbox has its own
  login.
- **Own sign-in only (D6).** No relay was offered. The devbox's own login answered, and
  the relay's log stayed empty. The first run of this test got no reply within 60 s, right
  after the relayed test. Two reruns (alone, then both together) passed in under 8 s. I
  haven't explained that first timeout.
- **This Mac not signed in.** `BareServerLiveTests.aBareServerGetsClaudeAndWithNoRelaySaysTheMacIsNotSignedIn`
  (US2): the real Linux agentsd answers `signInWanted`. Settings shows "needs this Mac
  signed in to it" (`US2-settings-servers-mac-signed-out.png`). The window's sheet is
  still unseen (see US2.md).
- **Offline mid-turn.** Unchanged by 056: the relay rides the same ssh master as
  everything else, and 037's offline handling ends the turn. Not walked again.

Seen along the way: agents left on the server by an earlier connection keep trying the
relay after that window has gone ("relay gate: the Mac's relay is not reachable"). That is
the offline case above, as it should be.
