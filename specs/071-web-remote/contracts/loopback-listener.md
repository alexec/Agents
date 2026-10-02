# Contract: the loopback listener

`agents-control`'s second listener: plain HTTP on `127.0.0.1:<port>` and `[::1]:<port>`, with
canonical origin `http://localhost:<port>` (default port 8792). Research R2, R3.

## Requests, in the order they are judged

| # | Condition | Answer |
|---|---|---|
| 1 | `Host` is not `localhost:<port>`, `127.0.0.1:<port>` or `[::1]:<port>` (case-insensitive) | `421 Misdirected Request`, empty body |
| 2 | Method is not `GET` | `405`, `Allow: GET` |
| 3 | `Host` is `127.0.0.1:<port>` or `[::1]:<port>`, and it is not an upgrade | `308`, `Location: http://localhost:<port><path>` |
| 4 | Path is `/v1/connect` with `Upgrade: websocket` | go to **Upgrade** |
| 5 | Path is `/v1/connect` without an upgrade, or an upgrade on any other path | `400` |
| 6 | Path (query dropped) is `/` or in `MANIFEST`'s `out` list | `200` with the file (`/` is `index.html`) |
| 7 | Anything else | `404`, empty body |

There is no `/healthz`, `/readyz`, `/v1/install.sh` or `/v1/servers/*` on this listener.

Chrome DevTools asks for `/.well-known/appspecific/com.chrome.devtools.json` by itself while it is
open (#114). That is row 7: `404`, empty, with every header. DevTools also reports it in the console
as a `connect-src` violation; that line is DevTools', not the page's, and stops nothing. `connect-src`
stays the page's one WebSocket: neither that URL nor `http://localhost:<port>` is added to clear it.

### Upgrade

| Condition | Answer |
|---|---|
| `Host` ≠ `localhost:<port>` | `421` (no redirect for an upgrade) |
| `Origin` absent, or not exactly `http://localhost:<port>` | `403` |
| Otherwise | `101`, then 058's exchange with **origin = `http://localhost:<port>`** (browser-auth.md) |

## Headers on every response, 200 or not

```text
Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; font-src 'self'; connect-src ws://localhost:<port>; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; frame-src 'none'; object-src 'none'; worker-src 'none'; manifest-src 'none'; require-trusted-types-for 'script'; trusted-types 'none'
X-Content-Type-Options: nosniff
Referrer-Policy: no-referrer
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Resource-Policy: same-origin
X-Frame-Options: DENY
Cache-Control: no-cache
Connection: close
```

Content types, by extension only:

| Extension | `Content-Type` |
|---|---|
| `.html` | `text/html; charset=utf-8` |
| `.js` | `text/javascript; charset=utf-8` |
| `.css` | `text/css; charset=utf-8` |
| `.svg` | `image/svg+xml` |
| `.png` | `image/png` |
| `.woff2` | `font/woff2` |

A file with any other extension in `MANIFEST` stops the listener from starting.

## Start-up

1. With no `--web` or no `--web-port`, or with `--no-web`, the listener does not start.
2. Read `<web>/MANIFEST`. Load each `out` file, and check its SHA-256. On any mismatch or a
   missing file, log `web: not serving, <path> does not match its manifest` and do not start.
3. Bind both addresses. If the port is taken, log `web: port <n> in use` and carry on without
   it. The TLS listener and hosts are unaffected.

## Logging

One line per request: `web <method> <path> <status>`. No query, no header, no body. An
upgrade's later lines follow the control plane's existing rules, which log no secrets.

## Tests (`Packages/ControlPlane/Tests/ControlPlaneKitTests/LoopbackListenerTests.swift`)

Each row of each table above is a test case, plus:
- the listener is not reachable on a non-loopback interface address of this machine;
- a path with `..`, `%2e%2e`, a NUL byte or a backslash gets 404;
- every header is present on 200, 308, 404, 405 and 421 alike.
