# S1 results: what the browsers give the web remote

**Outcome: pass in Chrome and Safari. The plan stands, with one byte rule added (the UUID's case).**

Spike T001, research R1. Run on 2026-10-01 on macOS 27.0, with
`python3 serve.py 8893` serving the page under the web remote's CSP. The vectors came from
`ControlAgreementVectorTests` (`Web/test/vectors.json`).

How to repeat it:

```sh
swift test --package-path Packages/AgentsKit --filter ControlAgreementVectorTests   # vectors fresh
cd specs/071-web-remote/spikes/s1-browsers
python3 serve.py 8893 &
node run-chrome.mjs 8893            # headless; --headed for a window
open -a Safari http://localhost:8893/   # then quit Safari, reopen, open the page again
```

## Chrome 154.0.8037.59, headless (`--headless=new`), throwaway profiles

Raw output: [chrome-headless.json](chrome-headless.json).

| Check | `localhost` | `127.0.0.1` |
|---|---|---|
| 1. `isSecureContext`, `crypto.subtle` | ✅ ✅ | ✅ ✅ |
| 2. Private key `extractable: false`; `pkcs8` and `jwk` export refused | ✅ | ✅ |
| 2. Public key raw, 65 bytes, starting `0x04` | ✅ | ✅ |
| 3. Key in IndexedDB after a clean quit (`Browser.close`) and relaunch on the same profile: same public key, same ECDH bits, still a non-extractable `CryptoKey` | ✅ | ✅ |
| 4. ECDH x = `sharedX` | ✅ | ✅ |
| 4. `clientKey` peer MAC matches; server MAC verifies | ✅ ✅ | ✅ ✅ |
| 4. `codeKey` peer MAC matches; server MAC verifies | ✅ ✅ | ✅ ✅ |
| 5. `persisted()` before, `persist()`, `persisted()` after | false, false, false | false, false, false |
| 5. The same in an incognito context | false, false, false | false, false, false |
| 5. `estimate().quota`, normal and incognito | 10 GiB, 10 GiB | 10 GiB, 10 GiB |
| Incognito: can it make and keep a key for the session? | ✅ | ✅ |

What it tells the plan:
- **Pass.** Checks 1–4 pass on both origins, so the canonical origin stays
  `http://localhost:8792`.
- **The UUID in HKDF's info is upper case.** That is Swift's `uuidString`, and so is the
  `c:` identity. The vectors check it: a lower-case UUID gives a different MAC
  (`lowerCaseUUIDWouldMatch: false`). `crypto.randomUUID()` is lower case, so the web app must
  upper-case the UUID once at pairing and store it that way. This goes into
  contracts/browser-auth.md and `keys.ts` (T022).
- **`persist()` is refused, and storage is best-effort.** Chrome grants persistence by its own
  heuristics (site engagement, bookmarks, an installed app), which a fresh localhost profile
  doesn't meet. The key still survived the restart. Best-effort storage is evicted only under
  disk pressure, or when the person clears site data, which the spec's edge cases already
  cover.
- **Chrome can't tell a private window apart.** `persisted()` and the quota are the same in
  incognito. Per R1's table, the private-window warning is dropped for Chrome, and the
  how-to says a private window forgets its key when it closes.
- **The spike's CSP** (`require-trusted-types-for 'script'`, `trusted-types 'none'`) caused no
  violations, with `textContent` as the only DOM write.

## Chrome 154.0.8037.59, headed

Run under the screen lease, with Alex's go-ahead, on throwaway profiles. Raw output:
[chrome-headed.json](chrome-headed.json). It is identical to headless on every check, both
origins, after a restart and in incognito, including `persist()` refused everywhere.

## Safari 27.0

Run by Alex in his own Safari at `http://localhost:8893/`:
1. open the page, which runs by itself;
2. quit Safari with ⌘Q;
3. reopen Safari and open the page again.

He reported the second run as **`pass: true`, `existedBefore: true`**. That covers:
- checks 1–4 all passed;
- the key made by the first run was read back after the restart, with the same public key and
  the same ECDH bits, and still non-extractable.

Not recorded for Safari, because Alex reported only the summary:
- what `persist()` and `persisted()` returned;
- a private window;
- the `127.0.0.1` origin.

None of them changes the plan:
- the canonical origin is `localhost`, which passed;
- the private-window warning is already dropped (it can't be shown in Chrome, so the how-to
  carries it for every browser);
- the 7-day ITP question needs a re-run after a week, and is left to the closing walk (T071),
  which reopens the same Safari origin.

## Firefox

Not installed, so not spiked ("Safari only for now", 2026-09-30).
