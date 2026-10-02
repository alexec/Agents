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
| R3 | Agents Host doesn't say when the page isn't being served | Low | Open |
| R4 | Script in the page holds the grant's full power, as the spec says | Accepted | By design; device by default |

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
- **Pair a Browser…** and **A browser on this Mac** make an ordinary client code: a grant, a five-minute life, one use.
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

### R3. Not serving is said only in a log (open)

**The problem:**
- When the port is taken, or now when `::1` is, the control plane logs `web: port 8792 not bound …; not serving the web remote`, and carries on.
- Agents Host's row still says **At http://localhost:8792, for a browser on this Mac only.**
- Someone who finds a page there that asks for a code has no sign that it isn't Agents.

**Suggested:** `control/status` reports whether the page is served, and Agents Host's row says **Not serving: something else has port 8792** when it isn't.

### R4. Script in the page has the grant's power (accepted)

As the table says, script running in the page can do anything the grant allows while the page is open. On a host, that includes running commands. The page keeps agent output from becoming script:

- **CSP:** `default-src 'none'`, own-origin scripts and styles only, no `unsafe-*`. `connect-src` names the one WebSocket. `frame-ancestors`, `form-action`, `object-src` and `base-uri` are all `'none'`. `require-trusted-types-for 'script'` with `trusted-types 'none'` means even a missed sink throws.
- **Rendering:** Markdown through markdown-it with `html: false`, built into Preact nodes, never HTML strings. Remote images become placeholders. Links open in a new tab with no opener or referrer, and only `http`, `https` and `mailto` are links. HTML files show as source. SVG is drawn only as an `<img>` made from its bytes.
- **Lint:** the source may not touch any HTML sink, evaluate strings, set cookies or make any request but its WebSocket.
- **Walks:** the US4 walk opened a hostile `.html` and `.svg` with CDP listening. Nothing logged, and nothing went anywhere.

Extensions are the browser's to police. The defaults keep this row small: a browser is a **Device** unless chosen otherwise, and **Forget This Browser…** cuts it off at once, in every tab.

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
   - Consider binding the browser client to an expiry with re-pairing, or a second factor for an operator grant. Also show each browser's last address and time in **Clients**, so a stranger's use is visible.
2. **Keep R2's binding.** It is what stops a phished browser code pairing any kind of client from anywhere. Once the page is public, a browser's code is good at the public listener only, and that listener must stay the one place it works.
3. **Origins and certificates.**
   - The canonical origin becomes the public `https://` name. The origin binding, the `Host` check and the `Origin` check must use it.
   - `connect-src` changes from `ws://localhost:<port>` to the `wss://` name.
   - HSTS should be sent, and certificate errors must not be clickable through. #61 provides the certificate.
4. **Brute force and load.** The loopback listener needs no rate limit. A public one needs limits on pairing and auth attempts per address, and a cap on open upgrades, before any of them reach the store.
5. **Tunnels.** If a tunnel (Tailscale, Cloudflare) stands in for #61, its own authentication is in front. The origin the page sees is still the tunnel's, and must be the one bound.
6. **The stolen-session table again.** Every row should be re-read with "anyone on the internet" added. The codes row ("a different account on this Mac … needs a code") becomes "anyone who sees a code in its five minutes". That argues for codes typed or scanned, never sent through chat or mail.
7. **Content.** The CSP and rendering rules stay as they are, and matter more: a script bug is then reachable from a link anyone can send. A `report-to` endpoint for CSP violations would show one being tried.
