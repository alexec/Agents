# Walk: US1, pairing a browser on this Mac (T035)

2026-10-01, on scratch root `/tmp/run-webus1` (run-app `launch.sh --slug webus1`, built from
`e052abc0`), with the web remote at `http://localhost:65187/`. Headless Chrome 154 with a
throwaway profile, driven by `Web/test/walk/us1.mjs`.

The window's Settings couldn't be pressed: this session has no Accessibility permission. So
Settings' calls (`clients/startPairing`, `clients/list`, `clients/setGrant`, `clients/forget`)
were made by `Web/test/walk/operator.mjs`, an operator client over the control plane's TLS
address that uses the web remote's own wire code, as kind `mac`. These are the calls the window
makes, through the same control plane.

## Results

| Scenario | What happened |
|---|---|
| 1. No key | Only the pairing screen ([us1-1-pairing.png](us1/us1-1-pairing.png)). |
| 2. Pairing with a device code | Paired, and Settings lists `Chrome on Alex’s MacBook Air · browser · device` ([us1-2-paired.png](us1/us1-2-paired.png)). |
| 3. Expired code | "This code has expired. Ask for a new one." ([us1-3-expired.png](us1/us1-3-expired.png)). |
| 3. Spent code | "This code has been used. Ask for a new one." |
| 4. Full browser restart | Connected again with its key, with no code. A second tab connected at the same time, on the same key. |
| 5. Forgotten in Settings | The page said **This browser was forgotten** after **60 ms** (budget: 2 s). Both tabs went to pairing, and IndexedDB was emptied ([us1-5-forgotten.png](us1/us1-5-forgotten.png)). |
| 6. Forget This Browser… | Confirmed in the page ([us1-6-confirm.png](us1/us1-6-confirm.png)). The page showed pairing with no "was forgotten" line, and Settings listed no browser. |
| 7. Promoted in Settings | After a reload the page said **Operator**; demoted again, **Device**. |

Across the walk there were:
- no page errors and no CSP reports;
- no request off the page's origin;
- console lines that were event names only (`link.connecting`, `link.open`, `link.forgotten`,
  `pair.ok`).

The `curl` checks against the same listener are in [us1/us1-curl.txt](us1/us1-curl.txt), and
all held:
- `GET /` returned 200 with every header;
- `127.0.0.1` redirected (308) to `localhost`;
- a foreign `Host` got 421, and `POST` got 405;
- an upgrade with a foreign `Origin`, or none, got 403;
- `/MANIFEST` got 404;
- only `127.0.0.1` and `[::1]` were listening.

## Not walked yet

- **The look of the Mac sheets:** the window's **Settings ▸ Control plane ▸ Clients ▸ Pair a
  Browser…**, the Browser row in Clients, and Agents Host's **Pair a Window or Phone… ▸ A browser
  on this Mac** with its **Serve Agents to browsers on this Mac** toggle. These need the screen,
  or Accessibility permission for this session. The Mac locked during the walk. Both schemes
  build, and the calls behind the sheets are the ones walked above.
- **Safari:** with Alex's go-ahead, in the closing walk (T071).
