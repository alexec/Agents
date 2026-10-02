# Security review: the web remote's first version

**Date:** 2026-10-01

**Commit:** the T073 commit on `agents/write-spec-first-version`.

This reviews what 071 adds to the attack surface, against the spec's stolen-session table:
- the loopback listener;
- the `browser` client kind;
- the origin binding;
- the page's CSP and rendering.

It ends with what #42 must add when #61 serves the page publicly. The tests that hold each row are mapped in [security.md](security.md).

## Findings

| # | Finding | Severity | Status |
|---|---|---|---|
| R1 | Another account could take `[::1]:<port>` and receive the page's visitors | Medium (another account on this Mac) | **Fixed** here |
| R2 | A browser's pairing code also pairs a phone or a Mac over TLS | Low now; higher once the page is public | **Fixed** here, at Alex's call |
| R3 | Agents Host doesn't say when the page isn't being served | Low | **Fixed** (#106) |
| R4 | Script in the page holds the grant's full power, as the spec says | Accepted | By design; **every client is an operator since #111** (2026-10-02), see R5 |
| R5 | One grant for every paired client: a stolen phone or a hijacked tab may do everything the window may | Accepted (Alex, 2026-10-02) | By decision, #111 |
| R6 | Open in Browser carries a browser code in the page's address (#109) | Low | **Checked**: safe as built, below |

### R1. The page's address could be taken on IPv6 alone (fixed)

**The problem:**
- The listener binds `127.0.0.1:<port>`, then `[::1]:<port>`. If the second bind failed, it logged and served on 127.0.0.1 alone.
- Browsers resolve `localhost` to both addresses, and may try `::1` first.
- Any account on this Mac can bind a port above 1024 on `::1`. One that took `[::1]:8792` before the control plane started (at login, or during the restart that **Serve Agents to browsers on this Mac** or an update makes) would receive the browser's requests.
- It would get them **at the page's own origin**, `http://localhost:8792`. Its page could then use the browser's stored key, which script can use though not read. It could also proxy the WebSocket on to the real listener at 127.0.0.1, setting `Host` and `Origin` as it likes, since it is a server.
- That is a whole session with the browser's grant, taken by another account. That is exactly what the table's row for another account says can't happen.

**The fix:**
- An address-in-use on `::1` now leaves the listener off, as one on 127.0.0.1 already did.
- Only a Mac with no IPv6 loopback at all (`EADDRNOTAVAIL`, `EAFNOSUPPORT`) falls back to 127.0.0.1 alone. There, nothing else can answer at `::1` either.
- Test: `aPortTakenOnIPv6AloneLeavesTheListenerOff`. It also checks that 127.0.0.1 on that port is let go.

**What remains:** an account that takes **both** addresses first gets the origin, but no real listener behind it to proxy to. A browser key works only through the loopback listener, so it can't be used at the TLS address. The squatter's page can still ask for a code, but since R2's fix a browser's code is good only through the real loopback listener, which isn't running while the squatter holds its port.

### R2. A code wasn't bound to the kind of client it was made for (fixed)

**The problem:**
- **Pair a Browser…** and **A browser on this Mac** make an ordinary client code: a grant (none since #111), a five-minute life, one use.
- The store records the purpose `client` and the grant, not the kind.
- The control plane refuses `kind: browser` through TLS and any other kind through loopback (`aBrowserCannotPairThroughTLSNorAnythingElseThroughLoopback`). But that check is on the kind announced, not on the code.
- So a code made for a browser can be announced over TLS as an iPhone or a Mac.

**Who gains:**
- Today, someone who reads a browser code before it is used. On this Mac that means another account squatting both loopback addresses (R1's remainder), with a lookalike pairing page at the real origin. Whatever is pasted into it, it redeems at the TLS address, which it can reach.
- With **do everything (Operator)** chosen, that is an operator.
- Codes are 16 random bytes, tagged by the control plane's key, so they can't be guessed. They can only be phished or seen.

**The fix (Alex chose to make it before merge):**
- A client code records whether it is for a browser, when it is made. `clients/startPairing` takes an optional `kind: "browser"`, and `agents-control code` takes `--browser`.
- The window's **Pair a Browser…** and Agents Host's **A browser on this Mac** ask for one.
- `announce` refuses a browser's code over TLS, and any other code through the loopback listener. It refuses before spending the code, so a code tried in the wrong place still pairs the browser it was made for.
- The page shows the control plane's words: "That code is for a window or a phone. Get one from Pair a Browser…."
- Tests: `aCodeIsGoodOnlyThroughTheListenerItWasMadeFor` (Swift), and "a code the control plane won't pair a browser with is refused in its own words (R2)" (`auth.test.mjs`).

### R3. Not serving was said only in a log (fixed)

**The problem:**
- When the port is taken, or now when `::1` is, the control plane logs `web: port 8792 not bound …; not serving the web remote`, and carries on.
- Agents Host's row still said **At http://localhost:8792, for a browser on this Mac only.**
- Someone who finds a page there that asks for a code has no sign that it isn't Agents.

**The fix (#106):**
- `control/status` carries `web`: the port, whether it is served and, if not, why (`portInUse`, `build` or `failed`). `control/webChanged` says when that changes.
- `serve --home` writes the same to `web.json` in its home, with its pid, for Agents Host, which isn't a client. A file left by an earlier run is ignored.
- Agents Host's row says **Not serving: port 8792 is in use by another app.** in place of the address, with **Try Again**, which sends the control plane `SIGUSR1` to bind again without dropping anyone.
- **Settings ▸ Control plane** in the window has a **Browsers on this Mac** row that says the same.
- Tests: `aTakenPortIsReportedAsNotServedAndTryingAgainServesOnceItIsFree`, the `portInUse` and `build` checks in the two tests above it, and `webJSONIsReadOnlyForTheRunThatWroteIt`.

### R4. Script in the page has the grant's power (accepted)

As the table says, script running in the page can do anything the grant allows while the page is open. On a host, that includes running commands. The page keeps agent output from becoming script:

- **CSP:** `default-src 'none'`, own-origin scripts and styles only, no `unsafe-*`. `connect-src` names the one WebSocket. `frame-ancestors`, `form-action`, `object-src` and `base-uri` are all `'none'`. `require-trusted-types-for 'script'` with `trusted-types 'none'` means even a missed sink throws.
- **Rendering:** Markdown through markdown-it with `html: false`, built into Preact nodes, never HTML strings. Remote images become placeholders. Links open in a new tab with no opener or referrer, and only `http`, `https` and `mailto` are links. HTML files show as source. SVG is drawn only as an `<img>` made from its bytes.
- **Lint:** the source may not touch any HTML sink, evaluate strings, set cookies or make any request but its WebSocket.
- **Walks:** the US4 walk opened a hostile `.html` and `.svg` with CDP listening. Nothing logged, and nothing went anywhere.

Extensions are the browser's to police. **Forget This Browser…** cuts it off at once, in every tab. The default that kept this row small, a browser paired as a **Device** unless chosen otherwise, went with #111 (R5): the grant is now everything the window may do.

### R5. One grant for every paired client (accepted, 2026-10-02)

**The decision:** Alex retired the `operator`/`device` split (#111). Every paired client (the Mac window, an iPhone, an iPad, a browser) may do what the window may. The pairing sheets no longer ask, `agents-control code --client` takes no grant, and the control plane and each host stop checking a per-grant allowlist.

**Why:** a device could already start agents and open terminals on any host, so it could run any command there: the device grant held back the screens (credentials, hosts, pairing, helper limits) but not the hosts themselves. It protected little and asked a question on every pairing sheet.

**The risk accepted:** a lost phone, a copied phone key, or script in a hijacked browser tab (R4) may also:
- pair more clients, which then outlive the theft until forgotten;
- forget the person's other clients, the last one included, so recovery is from Agents Host on the control plane's Mac (`agents-control code --client` there always works);
- add or remove hosts, lend a sign-in between hosts, sign runtimes in or out, change spending, helper and retention settings, approve workflows and plugins, and quit a host's daemon.

Until forgotten from another screen, or from Agents Host.

**What still holds:**
- Each client is still its own key. A phone's or a browser's connection to a host is bound to that client: presence is its own, and it can't name another device (`aDeviceMayDoWhatAWindowMay`, `nothingOnTheUplinkMakesAChannelAnAgentOrAStranger`).
- An agent's helper still reaches only its tools, and anything else of the account on the Mac reaches nothing: the socket's code-signature roles are unchanged.
- R1 and R2 are unchanged. R2 matters more now: a browser's code that paired a phone over TLS would be everything either way, so binding codes to their listener is what keeps a phished browser code on this Mac.
- Forgetting cuts a client off at once, on every copy.

**Older builds:** records, codes, channel opens and `ok` still carry `grant: operator`, which every older reader takes as everything. A `clients.json` record written as `device` reads as a full client and is written back as `operator`. An older window's grant picker is refused in words (`settingAGrantIsRefusedInWords`). An older host behind a new control plane gives a phone everything too, and until it updates counts the phone's presence as the Mac's, since it binds a device only for a `device` grant.

**For #42:** item 1 below asked for a second factor on an operator grant. With one grant that becomes a second factor, or an expiry, for every browser served publicly.

### R6. A code in the address: Open in Browser (#109, checked 2026-10-02)

**What it does:** the window's **View ▸ Open in Browser**, Settings ▸ Control plane's button and Agents Host's open `http://localhost:<port>/#code=<browser code>` in the default browser, when no browser of its family is paired. The page pairs with it in the same step. With one paired, they open the page with no code. If the control plane says the page isn't served, they say why and open nothing.

**Why it is safe:**
- **It is the same code.** It is made by `clients/startPairing {kind: "browser"}` (or `code --client --browser`): one use, five minutes, and good only through the loopback listener it was made by (R2). Nothing new is accepted anywhere.
- **It goes only to that listener.** The address is built from the control plane's own `control/status.web`: its port, and only while `served` is true. A squatter on the port (R1's remainder) means the control plane isn't serving, so nothing opens, and the code is never handed to whatever holds the port. A control plane on another Mac gets no address opened at all.
- **The fragment never leaves the browser.** Browsers don't send it in requests, so it can't reach the listener's access log or any proxy. The walk saw no request URL holding it.
- **It leaves the address at once.** `pairLink.ts` is imported first, takes `#code=` and calls `history.replaceState` before the router or anything else reads the address. The tab's address and Back hold no code. The page logs only `pair.fromLink`, never the code. The walk saw none in the console or the control plane's log.
- **What remains: browser history keeps it.** Chrome's History database keeps the address as first opened, code included (seen in the walk). By then the code is spent: replaying it from history in a fresh profile was refused as used. A code that isn't spent (the page never loaded, or a browser that was already paired ignores it) stays in history for at most its five minutes. Only this account can read that history, and that account can already use the browser's own key. Nor can another account use such a code, since R2 limits it to the real listener.
- **A paired browser doesn't spend it.** The page pairs only when it has no key. If the window guessed wrong (another browser family, or one whose site data was cleared), the code is left to expire, or used to pair, as a pasted one would be.

**Not done:** the control plane can't take an unused code back (`clients/stopPairing` does nothing there), so a code left unused lives its five minutes. That matters again with #61. A public page must not be opened with a code in its address unless one can be cancelled, or made to live for seconds.

## What was looked at and found sound

**The listener:**
- **What it answers:** only `GET`, only for files in its `MANIFEST`, checked against their hashes at start, so a changed build isn't served.
- **`Host`:** must be exactly `localhost:<port>` or a loopback address on that port, which stops DNS rebinding. The addresses are redirected to the name, so there is one origin.
- **The upgrade:** needs `Host` and `Origin` exactly the page's, else `421` or `403`.
- **Headers:** on every answer, a refusal included.
- **Reach:** not reachable off loopback (`itIsNotReachableOnAnotherAddressOfThisMac`).

**The `browser` kind and the origin binding:**
- **Each proof** is an HMAC over a transcript ending in the origin of the listener the socket arrived on. That origin comes from the listener, never from the request. A proof made for one listener fails on the other.
- **Kinds stay on their listeners:** a browser key is refused at the TLS address, and any other kind's at the loopback listener.
- **The key:** P-256, made with `extractable: false` and checked after it is stored. A browser that can't keep it so isn't paired at all.
- **Forgetting:** every socket of the client closes with 4403 within 2 s, on every copy. The next attempt is refused as `forgotten`.

**Ambient credentials:** none. No cookie is set or read. No HTTP authentication is asked for or honoured. No `GET` changes anything. A cross-site page can neither ride a request nor open the socket.

**Logs and the console:**
- The page writes only event names and error codes.
- The control plane's log was checked for codes, keys and a message's text across pairing, a refused proof and a call (`theLogHoldsNoCodeKeyOrMessage`).
- The listener's access log records method, path without its query, and status.

**Storage:**
- The page keeps the key in IndexedDB, and the chosen detail level in `localStorage`. Unsent drafts are held in memory only.
- A copy of the profile elsewhere carries the key, but nothing it can reach. That changes with #61.

## What #42 must add when #61 serves the page publicly

Once the page is served at the control plane's public address, the third row of the table ("a copy of the browser profile on another computer can do nothing") stops being true. Before then, #42 must cover these:

1. **The key works from anywhere.**
   - A copied profile, or malware that can drive the browser, is a session from anywhere.
   - Consider binding the browser client to an expiry with re-pairing, or a second factor (every client may do everything since #111, R5). Also show each browser's last address and time in **Clients**, so a stranger's use is visible.
2. **Keep R2's binding.** It is what stops a phished browser code pairing any kind of client from anywhere. Once the page is public, a browser's code is good at the public listener only, and that listener must stay the one place it works.
3. **Origins and certificates.**
   - The canonical origin becomes the public `https://` name. The origin binding, the `Host` check and the `Origin` check must use it.
   - `connect-src` changes from `ws://localhost:<port>` to the `wss://` name.
   - HSTS should be sent, and certificate errors must not be clickable through. #61 provides the certificate.
4. **Brute force and load.** The loopback listener needs no rate limit. A public one needs limits on pairing and auth attempts per address, and a cap on open upgrades, before any of them reach the store.
5. **Tunnels.** If a tunnel (Tailscale, Cloudflare) stands in for #61, its own authentication is in front. The origin the page sees is still the tunnel's, and must be the one bound.
6. **The stolen-session table again.** Every row should be re-read with "anyone on the internet" added. The codes row ("a different account on this Mac … needs a code") becomes "anyone who sees a code in its five minutes". That argues for codes typed or scanned, never sent through chat or mail.
7. **Content.** The CSP and rendering rules stay as they are, and matter more: a script bug is then reachable from a link anyone can send. A `report-to` endpoint for CSP violations would show one being tried.
