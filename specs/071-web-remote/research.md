# Research: The Web Remote, First Version

Each entry gives the decision, why, and what else was weighed. Code references are to main at
`3c9a3f60`, read as if 058 T106 has removed `Bridge/`, `DirectLink`, `SocketLink` spawning,
the `AGENTS_STORE` compile condition and TLS-PSK.

## R1 — Spike S1: what the browsers must do, and what happens if one can't

**Decision**: T001 is a spike, done before anything is built. It checks each browser against
five things, with one self-contained page, `specs/071-web-remote/spikes/s1-browsers/index.html`,
and a small script. The page is served from a scratch port by `python3 -m http.server --bind
127.0.0.1`, at `http://localhost:<port>`. The checks:
1. `window.isSecureContext` is true at `http://localhost:<port>`. `crypto.subtle` is present.
2. `generateKey({name:"ECDH", namedCurve:"P-256"}, false, ["deriveBits"])` gives a private key
   with `extractable === false`. `exportKey("raw", publicKey)` gives 65 bytes starting `0x04`,
   which is X9.63 as `ControlAgreement` expects.
3. The key pair is stored in IndexedDB by structured clone. After a **full quit and relaunch**
   of the browser it reads back as the same key: its public key is unchanged, and it still
   derives the same bits against a fixed peer key. `exportKey` on the private key still
   throws.
4. The derivation reproduces `ControlAgreement` byte for byte, with test vectors that a Swift
   test prints (`ControlAgreementVectorTests`): a fixed control key, client key and UUID,
   giving the expected `clientKey`, the code key and both MACs.
   - The page imports the fixed client private key as JWK for this check only. The real key
     is never imported.
   - It runs `deriveBits` (ECDH, 256 bits, which is the x coordinate), then `importKey("raw",
     …, "HKDF", false)`, then `deriveKey` (HKDF-SHA256 with salt `agents-control-client-v1` and
     info the UUID, as `{name:"HMAC", hash:"SHA-256", length:256}`, non-extractable), then
     `sign` and `verify`.
5. What `navigator.storage.persist()` and `persisted()` report, in a normal window and in a
   private one. This decides whether the page can warn that a private window won't keep its
   key (spec edge case).

**Browsers, as Alex decided on 2026-09-30:**
- **Chrome is installed.** It is spiked headless (`--headless=new`) with a throwaway
  `--user-data-dir`, quit and relaunched on the same directory. Then it is spiked headed once,
  under the screen lease, to compare.
- **Safari is spiked**, but restarting it means quitting Alex's own Safari. Safari also has no
  separate profile that can be driven without `safaridriver`, which Alex chose not to enable.
  So the Safari half is run by Alex, or by the agent with Alex's go-ahead at the time, asked
  with the question tool.
  - The page needs nothing but opening, one press, quitting Safari, reopening, and a second
    press.
  - It shows its results as text, and they are copied into `spikes/s1-browsers/results.md`.
- **Firefox is not installed** and is not spiked now ("Safari only for now"). The spec's
  browser assumption stays open for Firefox. The how-to names Safari and Chrome as tested.
  Installing Firefox later re-runs the same page.

**Outcomes, planned either way:**

| Result | What the plan does |
|---|---|
| All checks pass in Safari and Chrome | Build as planned. |
| `localhost` is not a secure context in one browser | Flip the canonical origin to `http://127.0.0.1:<port>`, which every current browser treats as potentially trustworthy by the Secure Contexts spec. The redirect (FR-004) runs the other way, and the origin bound into the exchange changes with it. The spec's wording about `localhost` is updated, and Alex is told. |
| ECDH, HKDF or HMAC output differs from Swift | The difference is in encoding: raw against X9.63, the bit length, or salt and info as UTF-8. Fix it in the spike until the vectors match. Nothing is built on a mismatch. |
| The key does not survive a restart in Chrome (persistence) | Test whether `navigator.storage.persist()` before storing changes it. If it still fails, stop and ask Alex: pairing again after each restart breaks US1's acceptance scenario 4. |
| The key does not survive a restart in Safari | Same as above. Safari's 7-day script-storage cap (ITP) does not apply to `localhost`, which the spike checks by recording the storage's age. If it does apply, the how-to says so, and the page warns once. |
| A non-extractable key cannot be stored at all in a browser | That browser is unsupported. The page detects it at runtime (try to store, read back, check `extractable === false`) and names the supported browsers (spec edge case). It never falls back to an exportable key. If both Safari and Chrome fail, stop and ask Alex. |
| `persist()` cannot tell a private window apart | Drop the private-window warning, and say in the how-to that a private window forgets its key when it closes. |

**Result (T001–T002, 2026-10-01)**: **pass** in Chrome 154 (headless and headed) and Safari
27.0. Details are in [spikes/s1-browsers/results.md](spikes/s1-browsers/results.md).
- **`http://localhost` is a secure context in both**, so the canonical origin stays
  `http://localhost:8792`. `127.0.0.1` was also a secure context in Chrome.
- **A non-extractable P-256 key survives a full quit and relaunch in both.**
- **Chrome's ECDH → HKDF → HMAC matches `ControlAgreement` byte for byte**, for client and code
  keys alike. In Safari the vectors check passed as part of `pass: true`.
- **One byte rule is added: the UUID is upper case** in both the `c:` identity and HKDF's
  info, as Swift's `uuidString` writes it. A lower-case UUID gives a different MAC, and
  `crypto.randomUUID()` is lower case.
- **`persist()` is refused in Chrome**, both normal and incognito. Storage is best-effort, and
  Chrome cannot tell a private window apart. Per the table above, the private-window warning
  is dropped, and the how-to says a private window forgets its key when it closes. Safari's
  `persist()` answer and ITP's 7-day cap are left to the closing walk (T071).
- **Firefox:** not installed, not spiked.

**Rationale**: Every later phase rests on these five facts. The spike costs an hour, and a
wrong guess would cost the pairing design.

**Alternatives considered**: Trusting the browsers' documentation without a spike was rejected,
because the spec asks for this spike. Playwright's bundled browsers were rejected because they
are not the browsers people use, and they add a large Node dependency.

## R2 — The loopback listener

**Decision**: `ControlService` starts a second `ServerBootstrap` beside the TLS listener. It
binds both `127.0.0.1:<port>` and `[::1]:<port>`, with no TLS, through a new
`LoopbackListener` that reuses `ControlWebSocketServer.configure` with three things added:
- a request gate (R3);
- a static file handler in place of the 404 fallback;
- an origin passed to the key exchange (R5).

- **Port: 8792.**
  - It is next to 8791 and unused in the repository.
  - 8790 was the bridge's, and is avoided even after T106, so an old Remote dialling 8790 never
    meets a web page.
  - A scratch root uses `--web-port`, or `AGENTS_CONTROL_WEB_PORT`, set by run-app to a free
    port. A scratch browser's key is bound to its own origin, so it never collides with the
    live one.
- **Flags on `agents-control`:** `--web DIR` (the built files), `--web-port N` and `--no-web`.
  - The listener starts only when it has both a directory and a port.
  - `--home`, Agents Host's single copy, defaults `--web-port` to 8792, and `--web` to the
    bundle's `Resources/web` that `ControlLauncher` passes in. So it is on by default (FR-002).
  - The container's entrypoint passes neither, so it is off. The image still carries the files,
    so an operator can turn it on behind their own tunnel later (#61).
- **Turning it off (FR-002):** Agents Host's window gets one toggle, **Serve Agents to
  browsers on this Mac**, stored in Agents Host's defaults. When it is off, `ControlLauncher`
  passes `--no-web`. Changing it restarts the control plane, as other Agents Host settings
  already do.
  - The toggle is a single line in the existing window, in the Mac's own words. It needs no
    new frame: frames A–F cover the browser, and this is a checkbox.
  - **Open:** if Alex wants a frame for it, it is a two-minute addition to `look/`.
- **What it serves:** `GET` for `/`, `/index.html`, `/app.js`, `/app.css` and the files under
  `/assets/` that `Web/dist/MANIFEST` lists, plus the upgrade at `/v1/connect`. Nothing else
  answers, not even `/healthz`, so the whole surface is the manifest (FR-003).
  - Files are read once at start into memory: about 200 KB, so nothing on disk can be swapped
    under the server.
  - Any path not in the manifest gets 404. Traversal is impossible, because nothing is looked
    up on disk by path.
- **Routing in the page** uses the URL fragment (`#/h/<host>/p/<project>/s/<session>`), so the
  server never needs to fall back to `index.html` for unknown paths. The browser's own Back
  moves between columns at narrow widths (US6, scenario 3).

**Rationale**:
- It reuses the NIO pipeline and the WebSocket upgrader `agents-control` already has, so no
  new dependency is needed.
- Two binds instead of one on `localhost`: "localhost" can resolve to either address, and the
  page must load whichever the browser tries first.

**Alternatives considered**:
- Serving on 8791 behind its self-signed certificate: the browser warns, and the page cannot
  check the pin.
- A separate web-server process: one more thing for Agents Host to supervise, and it would
  still have to proxy the socket.
- HTTP keep-alive and ETags: unnecessary on loopback for about 200 KB.

## R3 — Host, Origin and the headers

**Decision**: a gate before every request on the loopback listener.
- **`Host`** must be one of `localhost:<port>`, `127.0.0.1:<port>` or `[::1]:<port>`.
  Otherwise the answer is 421, with no body (FR-004, DNS rebinding).
  - `127.0.0.1` and `[::1]` get a 308 to `http://localhost:<port>` plus the same path, and
    no fragment, which the browser keeps.
  - A redirect is never sent for an upgrade. An upgrade on the wrong host gets 421.
- **`Origin`** on the upgrade must equal `http://localhost:<port>` exactly. A missing or other
  `Origin` gets 403, before the upgrade (FR-005).
  - The check sits in `NIOWebSocketServerUpgrader`'s `shouldUpgrade` closure, which sees the
    request head.
  - A request for a static file may carry any `Origin`. It changes nothing, and CORP stops
    another site from reading it.
- **Methods:** only `GET`, plus the upgrade's `GET`. Anything else gets 405.
- **Headers on every response**, the exact strings in
  [contracts/loopback-listener.md](contracts/loopback-listener.md):
  - CSP: `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:;
    font-src 'self'; connect-src ws://localhost:<port>; base-uri 'none'; form-action 'none';
    frame-ancestors 'none'; frame-src 'none'; object-src 'none'; worker-src 'none';
    manifest-src 'none'; require-trusted-types-for 'script'; trusted-types 'none'`;
  - `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`;
  - `Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Resource-Policy: same-origin`,
    `X-Frame-Options: DENY`;
  - `Cache-Control: no-cache`;
  - `Content-Type` from a fixed table keyed by extension.
  - `require-trusted-types-for 'script'` and `trusted-types 'none'` make Chrome refuse any
    `innerHTML` with a string. Safari and Firefox ignore them, so a build-time check (R12)
    covers them.
- **Access log:** method, path and status only, never a query or header (FR-033).

**Rationale**: these headers are the spec's FR-030 to FR-034, made concrete. The `Host` check
is what stops a rebound DNS name. The `Origin` check is what stops another site's script
opening the socket.

**Alternatives considered**:
- A token in the page, sent back on the upgrade: it adds a secret to the HTML, and the Origin
  and key checks already suffice.
- A CSP nonce: there is no inline script to allow, so `'self'` is enough.

## R4 — The browser's key

**Decision**:
- **Storage.** The key pair is made with `extractable: false` and kept in IndexedDB, in
  database `agents` and store `key`, under the single record `self`:
  `{privateKey: CryptoKey, publicKey: CryptoKey, client: uuid, control: base64url, paired: ISO
  date}`.
  - The public key is exportable; WebCrypto always makes it so. It is sent at
    `clients/announce`.
  - `control` is the control plane's public key from the code. The page checks it against
    every `hello` after pairing (FR-011).
- **Making it.** The page calls `navigator.storage.persist()` before the first key is made. It
  then reads the key back from IndexedDB and checks `extractable === false` before announcing.
  If that check fails, the browser is unsupported (spec edge case).
- **Forgetting it.** The page deletes the record and then the database. Both **Forget This
  Browser** and being forgotten do this (FR-014, FR-015).
- **Two tabs** share the record. Each opens its own socket: the router already allows several
  sessions of one client (`attachClient` makes a session id each time,
  ControlRouter.swift:413). A `BroadcastChannel("agents")` tells the other tabs when one tab
  pairs or forgets, so they follow at once. The channel carries no secret: only `paired` or
  `forgotten`.

**Rationale**: this is FR-009. Two sockets avoid a leader-election protocol between tabs. They
cost one channel per host per tab, which is negligible.

**Alternatives considered**:
- A `SharedWorker` holding one socket for all tabs: Safari's support has a history of gaps, and
  the CSP would need `worker-src`.
- Electing a lead tab with Web Locks: more moving parts for no benefit at this scale.

## R5 — The exchange, from the browser

**Decision**: the browser runs 058's exchange unchanged (`ControlAuth`). Only its origin is
new.
- **Origin.** The transcript's `origin` is `http://localhost:<port>`. `ControlAuth.origin`
  already maps `ws` to `http`.
  - The server binds the exchange to the **listener's own** canonical origin, never to anything
    the browser sends. So `ControlService.accept` takes the origin per listener: `origin` (TLS),
    `peerOrigin` (copies) or `webOrigin` (loopback).
  - A proof made on the loopback listener therefore fails on 8791, and the other way round
    (FR-006). `ControlServiceTests` gets a case for each direction.
- **With a code.**
  - The page parses `agents-control:2:c:<grant>:<key>:<secret>:<url>:<pin>:<name>` and ignores
    `url` and `pin` (spec assumption).
  - It opens `ws://localhost:<port>/v1/connect` and reads `hello`. If `hello.control` ≠
    `<key>`, it stops before sending anything and says **This code is for another control
    plane**.
  - Otherwise it sends `auth` with identity `p:<hex id>` and K = `codeKey(secret)` (HKDF-SHA256,
    salt `agents-control-code-v1`, empty info), and verifies `ok.mac`.
  - It makes its key, reads it back, and sends `clients/announce` with `kind: "browser"` and
    `name` set to the browser's product name ("Safari", "Chrome" or "Firefox", from
    `navigator.userAgentData` or the UA string).
  - The socket closes, and the page reconnects as `c:<uuid>`.
  - `refused` reasons map to the spec's words: `expired`, `spent`, `unknown` (wrong code) and
    `bad-proof`.
- **With its key.**
  - It sends `auth` with identity `c:<uuid>`. K comes from `deriveBits` (ECDH with the control
    key from the record), then HKDF with salt `agents-control-client-v1` and info the UUID, into
    a non-extractable HMAC key. The MACs are as in R1 (4).
  - `hello.control` must equal the stored `control`. Otherwise the page refuses to go on, and
    says the control plane on this port is not the one it paired with.
- **Naming (FR-010).**
  - For `kind: browser` on the loopback listener, the control plane names the record
    `"<name> on <this Mac's name>"`. The Mac's name is `Host.current().localizedName`, which is
    present wherever the loopback listener runs (Agents Host on macOS).
  - The page cannot learn the Mac's name without a fingerprinting API, so the control plane
    supplies it.
  - On Linux the name is left as sent. The listener is off there anyway.
- **`kind` is checked.** `browser` is accepted at `clients/announce` only on a session that
  came through the loopback listener. Any other kind is refused there. So a browser cannot pose
  as an iPhone, and an iPhone cannot pair as a browser through 8791.
- **Forgotten (FR-014).**
  - `router.forgetClient` already closes every session of the client.
  - The close is sent as WebSocket close code **4403** with reason `forgotten`, so the page
    knows at once, rather than guessing from a dropped socket.
  - On its next connection, the page also gets `refused: forgotten`, because a tombstone is
    read as forgotten for seven days. After that it is `unknown`, which the page treats as
    forgotten too.
  - Either way it deletes its key and shows **This browser was forgotten**.
- **Forgetting itself (FR-015).** `clients/forgetSelf`, with no params, is answered by the
  control plane for any grant, and only for the calling client. It refuses with `lastOperator`
  when the caller is the last operator. It is added to the pairing set's opposite: a method any
  paired client may call (contracts/browser-auth.md).
- **The derived secret.** `deriveBits` returns the shared x coordinate as an `ArrayBuffer`.
  The page imports it at once as a non-extractable HKDF key and drops its reference. That is
  the "passes through memory once per connection" in the spec's assumptions.

**Rationale**: everything the browser does is something `ControlAuth` already does. Only the
origin, the kind and one method are new.

**Alternatives considered**:
- ECDSA signatures instead of the MAC: WebCrypto supports them, but the server side would need
  a second code path (058 R6 chose MACs).
- Binding the exchange to the `Origin` header: the header is the browser's claim, while the
  listener's own origin is the server's fact.

## R6 — Generated protocol types, and how drift fails

**Decision**: a generator written in Swift, with swift-syntax, in `Packages/WebTypes`.
- **Source of truth.** The Swift source files under
  `Packages/AgentsKit/Sources/AgentsKitCore/`: `Daemon/DaemonAPI*.swift`,
  `Control/DaemonAPI+Control.swift`, `Control/Grant.swift` and `Control/ControlAuth.swift`, and
  the `Model/` types they reach.
- **The method table.** A new file, `Daemon/DaemonAPI+Web.swift`, holds `WebSignatures`: a
  plain Swift array of
  `(method: String, params: Any.Type, result: Any.Type, notification: Bool)`, one row per
  method or notification the web app uses.
  - It is real Swift, so a renamed or deleted type breaks the AgentsKit build at once.
  - A Swift test checks that every request row is in `ConnectionRole.deviceMethods`, or is
    `clients/forgetSelf` or `presence/report`. That enforces FR-016: the web app can only be
    typed against methods the device grant allows.
- **What the generator does.** `swift run --package-path Packages/WebTypes agents-webtypes`:
  1. parses the listed files with `SwiftParser`;
  2. starts from the type names in `WebSignatures`, and from the `Method` and `Notification`
     string constants;
  3. walks every type reachable through stored properties;
  4. emits `Web/src/protocol/generated.ts`.

  The emitted file holds:
  - a `Methods` map from each method string to `{params, result}`, and a `Notifications` map;
  - an `interface` per struct;
  - a string-literal union per `String` raw-value enum;
  - a tagged form per enum with associated values, matching Swift's synthesized `Codable`
    shape;
  - `Failure` codes as a `const` object;
  - a `Shapes` table: for each type, its required and optional keys. The TypeScript fixture
    tests use it to check that every fixture object has exactly the keys the Swift type has.
- **Mapping rules:**

  | Swift | TypeScript |
  |---|---|
  | `String`, `Character` | `string` |
  | `Int`, `Double` and the other numbers | `number` |
  | `Bool` | `boolean` |
  | `UUID`, `URL` | `string` (branded `UUID` and `URLString`) |
  | `Data` | `string` (base64, branded `Base64`) |
  | `Date` | `number`, seconds since 2001-01-01 (the wire's plain `JSONEncoder`, confirmed in T017), branded `WireDate` |
  | `T?` | `key?: T` |
  | `[T]`, `Set<T>` | `T[]` |
  | `[String: T]` | `Record<string, T>` |
  | `CodingKeys` with raw values | the renamed keys |
  | `RawRepresentable` structs (`HostID` and the like) | `string` brands |

- **What it refuses.** A type with a hand-written `init(from:)` or `encode(to:)` (DaemonAPI.swift
  has 29) cannot be read from its stored properties. The generator stops with an error naming
  it, unless `Packages/WebTypes/Overrides/<TypeName>.ts` gives its TypeScript by hand.
  - Each override must carry a fixture from the Swift encoder (R7), so a hand-written shape
    is still checked against real JSON.
  - An override for a type that no longer has a custom coder also fails, so overrides cannot
    go stale.
- **How drift fails the build (FR-035, SC-006).**
  1. `GeneratedIsFreshTests` in `Packages/WebTypes` runs the generator in-process on the
     working tree and compares its output with the checked-in `generated.ts`, byte for byte.
     It fails with the command to run (`scripts/web.sh types`) and the first differing line.
  2. CI runs `swift test --package-path Packages/WebTypes` on **every** pull request and push.
     The test selector is told that any change under `AgentsKitCore`, `Web/` or
     `Packages/WebTypes` selects it. Today CI runs neither this package nor `ControlPlane`, so
     T005 adds both.
  3. The web job's `tsc --noEmit` then fails any web code still using a field that was renamed
     or removed.
  4. The web job's `npm run build` with `git diff --exit-code` fails if `Web/dist` was not
     rebuilt after `generated.ts` changed (R8).

  Locally, `scripts/web.sh check` runs 1, 3 and 4. The Xcode builds of the apps do not run the
  generator: they do not consume the TypeScript, and adding swift-syntax to them would slow
  every build for nothing.
- **Determinism.** Types are emitted sorted by name, with a header naming the generator and
  the files read, but no date or commit, so the same source always gives the same bytes.

**Rationale**: the spec requires types generated from the Swift source (D5). Nothing in the
code links a method to its types, so a table is needed in any approach. A Swift generator
needs no Node, so the drift check runs wherever `swift test` does.

**Alternatives considered**:
- **JSON Schema from Swift, then a schema-to-TypeScript tool:** two generators where one is
  enough, and the schema step still needs swift-syntax.
- **Encoding sample values at runtime and inferring types:** misses optionals that happen to be
  nil, and every enum case not sampled.
- **SourceKit-LSP or `swift-symbolgraph-extract`:**
  - symbol graphs carry declarations but not `CodingKeys` raw values or custom-coder bodies;
  - they need a full build of AgentsKitCore first;
  - swift-syntax works on source text alone, in seconds.
- **The generator inside `AgentsKit`:** swift-syntax would then be built by every app target.

## R7 — Rules ported by hand, and the fixtures both sides run

**Decision**: fixtures in `Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/web/`, one folder
per rule. Each case is `{"name", "input", "expected"}`. The input is JSON from the Swift
encoders, and the expected output is plain JSON.
- **The rules, with their Swift source in `AgentsKitCore`:**
  - `groups/`: `AgentGroup.init(for:…)`, `settled()`, order within a group (`lastActivityAt`
    newest first; parked by `parking.parkedAt`) and the needs-you count (`Model/AgentGroup.swift`,
    `Client/AgentsModel.swift` 501–512, 875–966). This covers SC-005.
  - `status/`: `StatusShape` and its words (`UI/StatusShape.swift`).
  - `turns/`: `TurnParts`, `TurnDetail`, `TranscriptItem.display`, `omittingThoughts` and
    `joiningAdjacentToolRuns` (`Model/OutcomePage.swift`, `Model/TranscriptDisplay.swift`).
  - `background/`: `BackgroundUpdate.applying`, `disconnecting` and `BackgroundWords`
    (`Model/BackgroundWork.swift`).
  - `labels/`: `SessionLabelPolicy` (`Model/SessionLabel.swift`).
  - `reducer/`: a sequence of notifications (`agent/changed`, `agent/entry`, `agent/removed`,
    `agent/permission`, …) applied to an empty model by `AgentsModel.apply`, and a digest of the
    result: groups, counts, last entries and pending cards.
- **How the fixtures are made.** A Swift test helper writes the input and expected output from
  the Swift implementation when `AGENTS_WRITE_WEB_FIXTURES=1` is set. Without it,
  `WebFixturesTests` re-runs the Swift rules on every input and fails on any difference.
  - So the fixtures are always what Swift does.
  - The TypeScript port is tested against them by `npm test`, which reads the same folder by
    path.
- **Times.** Rules that read "now" take it as an input, which the fixture fixes.
- **What is not ported.** Anything already computed on the host and sent: turn summaries
  (`turns.jsonl`), changes (`changes/list`, `changes/file`) and files. The Remote rebuilds
  changes from the transcript, but the web app uses `changes/list`, which the device grant
  allows, so it has nothing to port.

**Rationale**: D5 and FR-036. With the fixtures in one place, a change to a Swift rule that is
not ported fails `npm test` in CI the moment its fixtures are regenerated. The Swift side
refuses fixtures it no longer matches, so they cannot be left stale.

**Alternatives considered**:
- Moving the rules to the host as new methods: this changes the Mac window and the Remote for
  no gain now.
- SwiftWasm for these rules alone: D6's spike, if drift happens in practice.

## R8 — The checked-in build, and how it stays in step with its source

**Decision**:
- **Deterministic build.** `Web/build.mjs` runs esbuild with:
  - fixed output names (`app.js`, `app.css`, no content hashes, because the manifest serves
    that purpose);
  - `minify`, and `legalComments: "eof"`;
  - no source maps, so no absolute paths are written;
  - `target: ["safari18", "chrome130", "firefox130"]`;
  - copying `index.html` and `assets/`.

  The Node version is pinned in `Web/.node-version` and checked by `build.mjs`. `npm ci
  --ignore-scripts` installs from the lockfile.
- **`Web/dist/MANIFEST`**, written by `build.mjs`:
  - one line per source input, `src <sha256> <path>`, covering every file under `Web/src/`,
    `Web/assets/`, `Web/index.html`, `Web/build.mjs`, `Web/tsconfig.json`,
    `Web/package.json`, `Web/package-lock.json` and `Web/.node-version`;
  - one line per output, `out <sha256> <path>`.
- **Three checks:**
  1. **No Node: `WebDistManifestTests`** (Swift, in `Packages/AgentsKit`, using CryptoKit).
     It hashes the source inputs and the outputs in the working tree, and compares both with
     `MANIFEST`. It fails if:
     - a source changed without a rebuild;
     - `dist` was edited by hand;
     - a file was added or removed.

     It runs in every `swift test` of AgentsKit, in CI and on the Mac. Changing `Web/src`
     without rebuilding therefore fails even for someone without Node.
  2. **With Node: the CI `web` job**, with the Node version from `Web/.node-version`.
     - It runs `npm ci --ignore-scripts`, then `npm run check`, which is `tsc --noEmit` and the
       R12 lint, then `npm test`, then `npm run build`, then `git diff --exit-code Web/dist
       Web/src/protocol/generated.ts`.
     - So `dist` must be byte for byte what this source and this lockfile produce.
     - This is D7's "CI fails when they differ from a fresh build".
  3. **The control plane** reads `MANIFEST` at start and serves only the files it lists, after
     checking their hashes. A hash mismatch logs one line and leaves the listener off, rather
     than serving a page that was not built.
- **Into the apps.**
  - `project.yml` copies `Web/dist` into Agents Host as a folder reference at
    `Contents/Resources/web`, with no build script, so Xcode needs no Node.
  - `deploy/Containerfile` copies it to `/usr/share/agents/web`.
  - The run-app skill passes `--web <checkout>/Web/dist` to the scratch control plane.
- **Git.** `.gitattributes` marks `Web/dist/**` and `Web/src/protocol/generated.ts` as
  `linguist-generated=true -diff`, so reviews show them folded. A merge conflict in either is
  resolved by regenerating, never by hand, and README says so.

**Rationale**:
- Two independent checks: the Swift manifest test (fast, no Node, local) and the CI rebuild
  (authoritative).
- The manifest also gives the server a closed list of what it may serve (R2).

**Alternatives considered**:
- Building in an Xcode run-script phase: every from-source build would need Node, which D7
  rules out.
- Downloading the bundle at release: developers building from source would have no web
  remote.
- Comparing only the output in CI: someone who edits `src` without Node, or commits without
  rebuilding, would not find out until CI. The manifest catches it in their own `swift test`.

**Amended (#473, 2026-10-08): `dist` is no longer checked in.**
- Every PR carried a rebuilt `dist`, and main took several merges per CI run, so each merge
  left every other open PR in conflict over files nobody writes by hand. Alex chose to stop
  committing it, which reverses D7's "building from source needs no Node" for the web page.
- `Web/dist/` is in `.gitignore`. Agents Host's target runs `scripts/web.sh dist` as a
  pre-build script: it builds when an input is newer than `MANIFEST`, and with no Node (or not
  the pinned one) it leaves an empty `Web/dist` and an Xcode warning. The app still builds,
  and with no `MANIFEST` the control plane keeps the web listener off (check 3).
- CI's test job installs the pinned Node before the Mac builds; `build-linux-control.sh`
  runs `web.sh build` before copying `dist` into the image.
- Check 1 runs only when a `dist` has been built. Check 2 builds, then tests; there is no
  committed copy to compare. `generated.ts` stays checked in and `GeneratedIsFreshTests`
  still holds it to the Swift.

## R9 — The web app's libraries

**Decision**: Preact with `@preact/signals`, markdown-it, esbuild and TypeScript. Nothing else
is shipped.
- **Preact.** It is about 4 KB, its components are close enough to SwiftUI's views to port
  layouts directly, and JSX text is escaped by default. Signals give fine-grained updates, so a
  streaming chat repaints one row, not the list.
- **markdown-it with `html: false`.** Raw HTML in agent text shows as text.
  - A custom `image` rule replaces any image whose `src` is not `blob:` or `data:` with a
    placeholder: "Picture not loaded: <alt> (<host>)" (FR-031).
  - A `link_open` rule sets `target="_blank" rel="noopener noreferrer"`.
  - Rendering is to tokens, then to Preact nodes, never to an HTML string, so Trusted Types
    never needs a policy.
- **Diffs and code** are shown as plain monospaced text with added and removed lines tinted.
  There is no syntax highlighting in this version: CodeText is Swift, and a highlighter would
  be the largest dependency.
- **Supply chain.**
  - Exact versions are pinned and installed with `npm ci --ignore-scripts`.
  - The lockfile is reviewed when it changes.
  - The licence check is part of `npm run check` (MIT, ISC, BSD or Apache only).

**Alternatives considered**:
- React: about ten times the size, for nothing used here.
- Lit: Web Components and shadow DOM fight the Paper palette's global CSS variables.
- Vanilla DOM: workable, but the reducer-to-view updates would be hand-written diffing.
- micromark: safe too, but harder to render to nodes without an HTML string.

## R10 — Walking it: headless Chrome, with Safari at the edges

**Decision, as Alex decided on 2026-09-30:**
- **Most walks run in headless Chrome** over the DevTools protocol:
  - with a throwaway `--user-data-dir` under the scratch root;
  - driven by `Web/test/walk/cdp.mjs`, a dependency-free CDP client using Node's built-in
    `WebSocket`;
  - which opens the page, presses by accessible name, sets the viewport for each width, and
    saves screenshots to `walks/`.

  No screen lease is needed, and Alex's windows are never touched.
- **The scratch Mac window** is driven by run-app as usual, beside it, so each walk shows the
  browser and the Mac window agreeing.
- **Safari is checked twice:** in the spike (R1), and in the closing walk (T071). Both need
  Safari quit and reopened, or at least driven by hand. They are asked of Alex with the
  question tool at the time, or done under the screen lease while he is away, if he says so.
- **Firefox is not walked** in this version (not installed).

**Rationale**: headless Chrome is real Blink with real WebCrypto and IndexedDB, and it can be
driven without the screen. That is what lets the layout walk come early and be repeated.

**Alternatives considered**:
- `safaridriver`: Alex chose not to enable it.
- Playwright: a large dependency that downloads its own browsers.

## R11 — Presence and the tab title

**Decision**:
- **Presence.** The page sends `presence/report{active, watching}`:
  - `active` is `document.visibilityState === "visible" && document.hasFocus()`;
  - it is sent on `visibilitychange`, `focus` and `blur`, debounced by 500 ms, and on every
    reconnect;
  - `watching` is the open session's id;
  - `mayNotify` is absent, because the browser takes no notices in this version.
- **The fold.** The router folds presence per client (ControlRouter.swift 123–155). With two
  tabs, one hidden, the client must count as active if **any** of its sessions is. T052
  checks the fold is per session, and changes it if it is per client: last report wins would
  let a hidden tab mark the person away.
- **The title** is `(N) Agents` when N sessions need the person, counted as the Mac window's
  `needsPersonCount` (needs-you plus blocked, across live projects), and `Agents` otherwise
  (FR-021).

## R12 — Keeping agent output inert, and secrets out of logs

**Decision**:
- **Rendering.** Every view renders strings through Preact text nodes. The only path from
  agent text to elements is the markdown-it token renderer (R9).
- **Files.**
  - HTML files show as source text.
  - SVG files show only as `<img src="blob:…">` made from the bytes, which browsers render
    with scripts off and no external loads.
  - Pictures go through the same `blob:` path.
- **A build-time lint** (`Web/test/lint.mjs`, run by `npm run check` and by the CI web job).
  As built in T008, it splits in two, because Preact's own bundle holds an `innerHTML`
  assignment, reached only through `dangerouslySetInnerHTML`.
  - **Our source, `Web/src`,** may not contain:
    - `innerHTML`, `outerHTML`, `insertAdjacentHTML` or `document.write`;
    - `dangerouslySetInnerHTML`, `DOMParser` or `createContextualFragment`;
    - `eval(`, `new Function`, or a timer given a string;
    - any `http://` or `https://` address.

    So Preact's `innerHTML` is never reached. Chrome's `trusted-types 'none'` would refuse it
    at run time as well.
  - **The built files, `Web/dist`,** may not contain `eval(`, `new Function` or an address
    outside an allowlist. The allowlist is the W3C namespace names Preact uses, plus licence
    comments. `index.html` may have no inline script, style or handler, and no reference off
    this origin.
- **Logging.** `Web/src/log.ts` is the only console writer. It takes a fixed event name and an
  error code, never a value. The wire client never logs lines, codes, keys or MACs.
  - A test runs the wire client against a fake server with `console` spied, and fails if any
    argument contains the code, the key bytes or a message's text (SC-008).
  - On the server, the loopback listener's access log is method, path and status. `ControlService`
    already logs no secrets, and a test case covers the new paths.
