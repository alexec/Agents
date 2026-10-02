# Security tests: the stolen-session table and FR-030 to FR-034

**Date:** 2026-10-01

**Commit:** the T069 commit on `agents/write-spec-first-version`.

Each row of the spec's "What a stolen browser session could do" table, and each of FR-030 to FR-034, is mapped below to the tests that hold it. T015, T016, T023, T025, T029 and T048 were audited against the table. Cases added by T069 are marked **new**.

**Where the tests live:**
- **Listener:** `LoopbackListenerTests`, in `Packages/ControlPlane/Tests/ControlPlaneKitTests/LoopbackListenerTests.swift`.
- **Browser client:** `BrowserClientTests`, in `…/BrowserClientTests.swift`.
- **Control service:** `ControlServiceTests`, in `…/ControlServiceTests.swift`.
- **Web tests:** in `Web/test/`.
- **Lint:** `Web/test/lint.mjs`, run by `npm run check`.

## The stolen-session table

| Who has it | Holding it | Tests |
|---|---|---|
| **Script running in the page** | Agent output can't run (FR-030, FR-031); the key can't be read; forgetting stops it at once (SC-007) | See FR-030 and FR-031 below.<br>The key can be used but never read: `auth.test.mjs` "a made key is P-256, non-extractable, with an upper-case id".<br>Forgetting cuts every socket within 2 s: `forgettingFromSettingsCutsTheBrowserOffWithinTwoSeconds`, `aForgottenClientIsCutOffAndRefusedAfter` (T029).<br>The page forgetting itself: `aBrowserForgetsItselfAndIsThenRefusedAsForgotten`, `forgetSelfIsOpenToADeviceAndOnlyForgetsItself`. |
| **Another process of this account** | Nothing new is exposed | No test: by design, there is nothing for one to hold. The listener adds no file and no socket that this account couldn't already reach, and the key lives in the browser's own storage. |
| **A copy of the browser profile on another computer** | The listener is loopback-only, so the key works only on this Mac | `itIsNotReachableOnAnotherAddressOfThisMac`.<br>A browser key is refused on the TLS address, which is the one other computers reach: `aBrowserKeyIsRefusedOnTheTLSAddress`. |
| **A different account on this Mac** | It reaches the listener but has no key, and a code works once, for five minutes | **new** `aBrowserCodeWorksOnceOnTheLoopbackListener` (the second use is refused as `spent`).<br>**new** `anExpiredCodeIsRefusedOnTheLoopbackListener` (`expired`, and the lifetime is 5 minutes).<br>**new** `aKeyNobodyPairedIsRefusedOnTheLoopbackListener` (`unknown`).<br>Only a client code pairs here: `aHostCodeIsRefusedOnTheLoopbackListener`, `aBrowserCannotPairThroughTLSNorAnythingElseThroughLoopback`. |
| **A website the person visits** | Its WebSocket is refused on `Origin` (FR-005), DNS rebinding on `Host` (FR-004), and it has no key | FR-005: `theUpgradeNeedsThisPagesOrigin`, `connectWithoutAnUpgradeOrAnUpgradeElsewhereIsBad`.<br>FR-004: `aHostThatIsNotThisListenerIsMisdirected`, `theAddressesRedirectToTheName`.<br>No key: **new** `aKeyNobodyPairedIsRefusedOnTheLoopbackListener`.<br>Nothing ambient to ride on: **new** `noCookieAndNoHTTPAuthenticationEitherWay` (FR-032). |

**FR-006, the proof bound to the listener's origin**, is the code row in SC-007:
- `aProofMadeForTheTLSAddressFailsOnTheLoopbackListener` and `aProofMadeForTheLoopbackListenerFailsOnTheTLSAddress`;
- `aWindowKeyIsRefusedOnTheLoopbackListener`;
- `auth.test.mjs` "a proof made for another origin doesn't match", "a code for another control plane sends nothing" and "a control plane that can't prove the code is refused before a key is made";
- each refusal word: `auth.test.mjs` "each refusal is said as itself".

**An operator grant** adds the operator's powers to the first row. A device can't do what only an operator may: `aDeviceIsRefusedWhatOnlyAnOperatorMayDo`. And the last operator can't forget itself: `theLastOperatorCannotForgetItself`.

## FR-030 to FR-034

| Requirement | Tests |
|---|---|
| **FR-030** CSP and headers | `everyAnswerCarriesTheHeaders` checks every header on every status: a file, a 404, a 405, a 421, a redirect and both connect paths. It was widened (**new**) to check each CSP clause the requirement names: own-origin scripts, styles, fonts and images (images also from `blob:` and `data:`), the one WebSocket in `connect-src`, `frame-ancestors`, `frame-src`, `object-src`, `form-action` and `base-uri` all `'none'`, no `unsafe`, and Trusted Types. It also checks the values of `nosniff`, `no-referrer`, both same-origin policies and `X-Frame-Options: DENY`.<br>The built page carries no inline script, style or handler: `lint.mjs` over `dist/index.html`. |
| **FR-031** Rendering without raw HTML | `render.test.mjs` (T048): "a script tag is text", "raw HTML blocks are text", "a remote image is a placeholder, not a request", "a javascript: link is not a link", "a data: or file: link is not a link", "an https link opens in a new tab without the opener", "only http, https and mailto are safe".<br>**new** "an HTML file is its source, an SVG only a picture (FR-031)", against `textShownAs`, which `FileView` now draws from.<br>`lint.mjs` bans every HTML sink in the source (`innerHTML`, `dangerouslySetInnerHTML`, `DOMParser`, `document.write` and the rest).<br>The US4 walk opened a hostile `.html` and `.svg` while CDP listened, and recorded no console call and no request off the origin (`walks/us4.md`). |
| **FR-032** No ambient credential | **new** `noCookieAndNoHTTPAuthenticationEitherWay`: no answer sets a cookie or asks for authentication, and a request carrying `Cookie` and `Authorization` is answered byte for byte as one without.<br>**new** `lint.mjs` rule: the source may not touch `document.cookie`, pass `credentials`, or make any request but its WebSocket (`fetch`, `XMLHttpRequest`, `sendBeacon`, `EventSource`). A local callback named `fetch` in the chat was renamed `loadDetail` so the rule could hold. |
| **FR-033** No secret in a log or the console | The console: `secrets.test.mjs` (T025) pairs and sends a prompt through `link.ts` with `console` spied.<br>The control plane's log: **new** `theLogHoldsNoCodeKeyOrMessage`. It pairs a browser, makes a refused proof, and sends a call carrying a marker message. It then checks the log for the code, the marker, and the code secret, shared key, browser private key and control private key, each in base64 and in hex. None is there.<br>To hear the log, `ControlService.Configuration` gained an optional `log` sink, which is standard error when unset, as before. |
| **FR-034** Nothing from another origin | `lint.mjs`: no address in the source; none in the built JS or CSS outside the namespace allowlist and licence comments; no CSS `@import` or remote `url()`; the HTML references only same-origin paths.<br>The closing walk (T071) captures every request across a whole walk (SC-008). |

## What a test cannot hold

- **Extensions.** A malicious extension is the first row's thief, and the browser's to police. Forgetting the browser is the remedy, and that is tested.
- **The listener's access log** records a method, a path and a status (`web GET / 200`), which FR-033 allows. The page never puts a code or key in a URL: pairing and connecting happen inside the WebSocket.
