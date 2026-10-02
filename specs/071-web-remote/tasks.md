---
description: "Tasks for 071, the web remote's first version: a browser on this Mac as a client of the control plane"
---

# Tasks: The Web Remote, First Version: a Browser on This Mac

**Input**: the design documents in `specs/071-web-remote/`: spec.md, plan.md, research.md (R1–R12),
data-model.md, `contracts/` (loopback-listener, browser-auth, generated-types) and
quickstart.md. The look gate, frames A–F in `look/`, was approved by Alex on 2026-09-30.

**Tests**: the spec asks for them where it names a check:
- SC-005: the shared fixtures;
- SC-006: types that cannot drift;
- SC-007: each refusal in the stolen-session table;
- SC-008: no secret leaks and no other origin;
- FR-035a: the checked-in build.

Each phase from US1 on ends with a walk from quickstart.md, recorded in `walks/`.

**Rules for every walk**:
- scratch roots and scratch ports only, never 8792, the real root or Alex's devices;
- headless Chrome with a throwaway profile (research R10);
- Safari only with Alex's go-ahead, asked with the question tool.

**Against what**: 058 after T106 and T042. `Bridge/`, `DirectLink`, the `AGENTS_STORE` switch,
`SocketLink` spawning and TLS-PSK are gone. The web remote speaks only the control plane's
WebSocket protocol.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1–US7, as in spec.md

---

## Phase 1: The spike (plan Phase 0)

**Purpose**: prove what the browsers must do before anything rests on it. Nothing in Phase 2
starts until T002 is written up.

- [x] T001 (Chrome 154 headless + headed, Safari 27.0 by Alex: pass; spikes/s1-browsers/results.md) Spike S1, the browsers, in `specs/071-web-remote/spikes/s1-browsers/`, as research R1. It has four parts:
  1. **Vectors.** Add `ControlAgreementVectorTests` to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/`. It fixes a control key, a client key, a UUID, a code secret, both nonces and the origin `http://localhost:8893`. It writes the expected ECDH x, `clientKey`, `codeKey`, peer MAC and server MAC to `Web/test/vectors.json`, and fails when the checked-in file differs.
  2. **The page.** Write `index.html` and `spike.js`. The script has no dependencies; the page has no inline script, and is served with the CSP from contracts/loopback-listener.md by a 20-line `serve.py`, so the check runs under the real policy. It runs research R1's five checks and prints the results as text:
     - secure context;
     - non-extractable P-256, with the public key raw and 65 bytes;
     - the key kept in IndexedDB across a full quit;
     - ECDH → HKDF → HMAC matching `vectors.json`;
     - `navigator.storage.persist()` and `persisted()`, in a normal and a private window.
  3. **Chrome.** Write `run-chrome.mjs`. It launches `/Applications/Google Chrome.app` headless with `--user-data-dir` under `/tmp/s1-chrome`, over CDP, runs the page, quits, relaunches on the same profile and runs it again, at both `http://localhost:8893` and `http://127.0.0.1:8893`. Repeat once headed, under the screen lease (lease `screen`, release at once).
  4. **Safari.** Ask Alex with the question tool whether he runs the Safari half himself (open the page, **Run**, quit Safari, reopen, **Run**), or lets the agent do it under the screen lease while he is away. Either way, copy Safari's printed results.

  Write everything to `spikes/s1-browsers/results.md`. Firefox is not installed and is not spiked ("Safari only for now", 2026-09-30).
- [x] T002 (all pass; the origin stays localhost; added: the UUID is upper case, and the private-window warning is dropped; research R1 Result) Act on the spike, with research R1's outcome table. Record the outcome in research.md R1 under **Result**.
  - **All pass:** carry on.
  - **`localhost` is not a secure context in a browser:** flip the canonical origin to `http://127.0.0.1:<port>` in research R2/R3/R5, contracts/loopback-listener.md, contracts/browser-auth.md and the spec's FR-004/FR-005/edge case. Tell Alex in the turn's ending.
  - **Vectors differ:** fix the byte handling in the spike until they match. Nothing goes on until they do.
  - **Persistence fails in Safari or Chrome, or neither can keep a non-extractable key:** stop, and ask Alex with the question tool. Pairing again after each restart breaks US1 scenario 4.
- [x] T003 (2026-10-01: T106 and T042 merged; rebased onto 0d2adaf0; Bridge/, LinkTLS, AwayLink and AGENTS_STORE gone; ControlPlane's 52 tests pass) Rebase onto main once 058 T106 and T042 have merged (they are on `agents/do-058-s-t106`), and check with `git merge-base` that the rebase landed on this branch.
  - Confirm that `Bridge/`, `DirectLink`, `SocketLink` spawning, `LinkTLS`, `AwayLink` and the `AGENTS_STORE` compile condition are gone.
  - Run `swift test --package-path Packages/ControlPlane`. It must pass before Phase 3.
  - If T106 has not merged by then, start Phase 2 on main as it is. Phase 2's files (`Packages/ControlPlane`, `ControlDial.swift`, `ControlAuth.swift`, `Grant.swift`) are not ones T106 removes.

---

## Phase 2: Setup (plan Phase 1)

**Purpose**: the `Web/` app, the generator package and the checks that keep checked-in files in
step with their sources, before any feature code.

- [x] T004 (8e4afe60: preact 11.0.0, @preact/signals 2.11.3, markdown-it 15.0.2, esbuild 0.28.2, typescript 7.0.2; same bytes from any path) [P] Create the `Web/` skeleton, as plan.md's structure and research R8/R9.
  - `package.json`, with exact versions of `preact`, `@preact/signals`, `markdown-it`, `esbuild` and `typescript`, and the scripts `build`, `check` and `test`.
  - `package-lock.json`, `.node-version` (the Node in use here, v26.8.2), and `tsconfig.json` (`strict`, `noUnusedLocals`, `noUncheckedIndexedAccess`, ES2022).
  - `build.mjs`. It checks the Node version, builds deterministically with fixed names and no source maps, copies `index.html` and `assets/`, and writes `dist/MANIFEST` (data-model.md).
  - `index.html`, with no inline script or style, and a `src/main.tsx` that renders "Agents".
  - Run `npm ci --ignore-scripts && npm run build`, and check in `Web/dist/`.
- [x] T005 (8e4afe60) [P] Add `.gitattributes` entries marking `Web/dist/**` and `Web/src/protocol/generated.ts` as `linguist-generated=true -diff`, and add `Web/node_modules/` to `.gitignore`.
- [x] T006 (8e4afe60; uses ControlAgreement.sha256, so no CryptoKit; dotfiles skipped on both sides) [P] Add `WebDistManifestTests` in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/WebDistManifestTests.swift`, as research R8 check 1. It finds the repository root from `#filePath`, hashes the source inputs and `dist` outputs with CryptoKit, and compares them with `Web/dist/MANIFEST`. It fails with a message for each case: a stale build, a hand-edited `dist`, or an added or missing file. To prove it, assert against a copy of the tree in a temporary folder (memory: never mutate source to prove a test).
- [x] T007 (38ac390d: swift-syntax 604.0.0 for Swift 6.4; GeneratedIsFreshTests brought forward from T021, holding a header-only generated.ts) [P] Create the `Packages/WebTypes` package.
  - `Package.swift`: macOS 27, swift-syntax pinned to the toolchain's version, `.treatAllWarnings(as: .error)`.
  - `Sources/WebTypesKit/` with an empty emitter, and `Sources/agents-webtypes/main.swift` taking `--root <repo>` and `--check`.
  - `Tests/WebTypesTests/`.
- [x] T008 (8e4afe60, as `Web/test/lint.mjs` and `licences.mjs`: the sink ban is on `Web/src`, because Preact's bundle holds `innerHTML` behind `dangerouslySetInnerHTML` (research R12); PSF-2.0 allowed, for argparse, which markdown-it uses only on its command line) [P] Add `Web/test/lint-dist.mjs`, as research R12. It fails on `innerHTML`, `outerHTML`, `insertAdjacentHTML`, `document.write`, `eval(`, `new Function` or `dangerouslySetInnerHTML` in `dist/app.js`, on any `http(s)://` outside an allowlist, and on inline script or style in `dist/index.html`. Also add a licence check over `package-lock.json` that allows MIT, ISC, BSD and Apache only. Wire both into `npm run check`.
- [x] T009 Write `scripts/web.sh` with these subcommands:
  - `types`: `swift run --package-path Packages/WebTypes agents-webtypes --root .`;
  - `build`: `cd Web && npm ci --ignore-scripts && npm run build`;
  - `check`: the WebTypes freshness test and `WebDistManifestTests`, then, if Node is present, `npm run check`, `npm test`, `npm run build` and `git diff --exit-code Web/dist Web/src/protocol/generated.ts`;
  - `test`: `npm test`.
- [x] T010 (a `packages` job on xcode-27 for WebTypes and ControlPlane, apart from `test` and its 30-minute cap; a `web` job on ubuntu-latest; the selector outputs `webtypes` and `controlplane`, and `Web/` changes select WebDistManifestTests and ControlAgreementVectorTests; not yet run on GitHub) CI, in `.github/workflows/ci.yml` and `scripts/select-test-suites.sh`:
  - run `swift test --package-path Packages/ControlPlane` and `swift test --package-path Packages/WebTypes` (neither runs in CI today);
  - make the selector choose WebTypes on any change under `Packages/AgentsKit/Sources/AgentsKitCore/`, `Packages/WebTypes/` or `Web/`;
  - add a `web` job on `ubuntu-latest` with `actions/setup-node`, reading `Web/.node-version`, that runs `npm ci --ignore-scripts`, `npm run check`, `npm test` and `npm run build`, then `git diff --exit-code Web/dist Web/src/protocol/generated.ts`.

**Checkpoint**: `scripts/web.sh check` passes, the manifest test fails on a stale copy, and
the CI change is ready to push with the branch.

---

## Phase 3: Foundational (plan Phase 2)

**Purpose**: the listener, the origin-bound exchange, the generated types and the web app's
wire client. Every story needs them.

### The loopback listener

- [x] T011 (unknown kinds read as `unknown`, so an older window still lists every client; browsers are left out of the relay's devices and notices) Add `browser` to `ClientRecord.Kind` in `Packages/AgentsKit/Sources/AgentsKitCore/Control/Grant.swift`. Test in `ControlGrantTests` that an older record still decodes, and that `browser` round-trips.
- [x] T012 (`Arrival` .tls / .loopback(origin); the kind rule also applies when a paired client connects, recorded in contracts/browser-auth.md) Pass the exchange's origin per listener in `Packages/ControlPlane/Sources/ControlPlaneKit/ControlService.swift`, as research R5:
  - `accept(…, origin:)` takes it from the listener, never from the request: `origin`, `peerOrigin` or `webOrigin`;
  - `ClientSession` gains `via: .tls | .loopback`;
  - `clients/announce` accepts `kind: browser` only via loopback, and only `browser` there;
  - a browser record is named `"<name> on <Host.current().localizedName>"`.
- [x] T013 (`Server/LoopbackListener.swift`: `WebFiles`, a pure `LoopbackGate`, two binds; `ControlDial.connect` can send an `Origin`, for tests) Build `LoopbackListener` and `StaticFiles` in `Packages/ControlPlane/Sources/ControlPlaneKit/Server/`, as contracts/loopback-listener.md:
  - bind `127.0.0.1` and `::1`;
  - judge each request in the contract's order: Host, method, redirect, upgrade, files;
  - check `Origin` in the upgrader's `shouldUpgrade`, added as a hook to `ControlWebSocketServer.configure` in `Packages/AgentsKit/Sources/ControlDial/ControlDial.swift`;
  - load the files from `MANIFEST` with their hashes checked, send the fixed headers, and keep the access log to method, path and status.

  Start it from `ControlService` when configured.
- [x] T014 Add `--web DIR`, `--web-port N` (and `AGENTS_CONTROL_WEB_PORT`) and `--no-web` to `Packages/ControlPlane/Sources/agents-control/main.swift`, with `--home` defaulting the port to 8792, as data-model.md. Update the header comment that lists the flags.
- [x] T015 (12 tests) [P] Add `LoopbackListenerTests` in `Packages/ControlPlane/Tests/ControlPlaneKitTests/LoopbackListenerTests.swift`. There is one case per row of contracts/loopback-listener.md's tables, plus:
  - traversal attempts;
  - every header on every status;
  - not reachable on a non-loopback address;
  - a manifest mismatch leaves the listener off;
  - a taken port leaves TLS up.
- [x] T016 (as `BrowserClientTests`, 9 tests, using ControlServiceTests' helpers) [P] Extend `ControlServiceTests` in `Packages/ControlPlane/Tests/ControlPlaneKitTests/ControlServiceTests.swift` for the origin binding:
  - a loopback proof fails on TLS, and a TLS proof fails on loopback;
  - `kind` is refused on the wrong listener;
  - two sockets of one browser client work at once;
  - a browser record is named after this Mac.

### Generated types (research R6, contracts/generated-types.md)

- [x] T017 (a plain JSONEncoder: Date is seconds since 2001-01-01, Data base64, UUID upper case; contracts/generated-types.md) Confirm how the daemon wire encodes `Date` and `Data`: find the `JSONEncoder` that `DaemonServer` and `DaemonClient` use. Write the answer into contracts/generated-types.md's mapping (`WireDate`).
- [x] T018 (56 rows, as `DaemonAPI.WebSignatures`; `DaemonAPI.Empty` added; ad-hoc results are `JSONValue`; `daemon/ping` left out, since a control plane passes it to the home host; `ControlMethods.anyGrant` made internal for the test) Write `WebSignatures` in `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI+Web.swift`. It has a row for every method and notification in data-model.md's lists, with the exact `DaemonAPI.Method` and `Notification` constants and their params and result types, read from the handlers in `DaemonCore`. Add `WebSignaturesTests` in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/`: every `hostRequest` is in `ConnectionRole.deviceMethods`, `controlRequest`s are limited to the control plane's device-grant methods, and no method appears twice (FR-016).
- [x] T019 (reads the whole AgentsKitCore tree; reads plain keyed `encode(to:)` bodies, so `Agent` needs no override; 18 emitter tests) Write the generator in `Packages/WebTypes/Sources/WebTypesKit/`:
  - parse the input files with `SwiftParser`;
  - resolve the roots from `WebSignatures` (read as syntax);
  - walk the reachable stored properties;
  - apply the mapping table, `CodingKeys` raw values and the enum forms;
  - emit `Methods`, `Notifications`, `Failure`, the types and `Shapes`, sorted and deterministic;
  - stop on each failure mode in the contract.

  Add emitter unit tests for each mapping-table row and each failure mode in `Packages/WebTypes/Tests/WebTypesTests/EmitterTests.swift`.
- [x] T020 (12 overrides; a hand-written `init(from:)` alone needs none; their fixtures wait for T042, as planned) Write overrides for every type the generator stops on (a custom coder, of which `DaemonAPI.swift` has 29 in all), in `Packages/WebTypes/Overrides/<Type>.ts`. For each, add a Swift-encoded sample to `Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/web/overrides/<Type>.json`, its sample is written by T042, which comes later; until then the override is checked only by `tsc`. If this list grows past about 15 types, stop and ask Alex whether some should get synthesized coders instead.
- [x] T021 (1,613 lines; `tsc` clean; plus `protocol/dates.ts`) Generate `Web/src/protocol/generated.ts`. Add `GeneratedIsFreshTests` in `Packages/WebTypes/Tests/WebTypesTests/`: it runs the generator in-process on the working tree, compares the output byte for byte, and fails with `scripts/web.sh types` and the first differing line. Write `Web/src/protocol/methods.ts`: a typed `call<M extends keyof Methods>(host, method, params)`.

### The web app's wire client

- [x] T022 (plus `wire/bytes.ts` and `wire/code.ts`; the BroadcastChannel between tabs moves to T031, where the page uses it) [P] Write `Web/src/wire/keys.ts`, as research R4 and data-model.md:
  - `storage.persist()`, then `generateKey` (non-extractable);
  - the client id made with `crypto.randomUUID().toUpperCase()` (spike S1);
  - IndexedDB `agents`/`key`/`self`;
  - read back and check `extractable === false`;
  - export the public key as raw;
  - delete the record and the database;
  - a `BroadcastChannel("agents")` carrying `paired` and `forgotten`.

  Unit-test the crypto in `Web/test/keys.test.mjs` with Node's WebCrypto. IndexedDB is covered by the walks.
- [x] T023 (8 tests; the browser's code and key proofs match Swift's bytes; `clients/announce` is a bare JSON-RPC line, contract corrected) [P] Write `Web/src/wire/auth.ts`: both exchanges in contracts/browser-auth.md, the `hello.control` checks, the refusal words and the code parser. Test in `Web/test/auth.test.mjs` against `Web/test/vectors.json`, and against a fake server in the test, for each refusal, a wrong control key and an unparseable code.
- [x] T024 (9 tests; the heartbeat is `control/status`, since a control plane passes `daemon/ping` to its home host; `surface/identify` per host moves to the page, T036) Write `Web/src/wire/link.ts`:
  - one socket per tab to `ws://<location.host>/v1/connect`;
  - auth, then `{h, m}` lines with the page's own request ids;
  - notifications dispatched by method;
  - `hostOffline` and other failures typed from `Failure`;
  - close 4403 means forgotten;
  - backoff 1, 2, 4, 8, then 10 s with jitter, and an immediate retry on `visibilitychange`;
  - a `daemon/ping` every 5 s with a 3 s timeout to notice a hung socket;
  - `surface/identify` on open.

  Test in `Web/test/link.test.mjs` with a fake server.
- [x] T025 [P] Write `Web/src/log.ts`, the only console writer: a fixed event name and an error code. Add `Web/test/secrets.test.mjs`, which runs pairing and a prompt through `link.ts` against the fake server with `console` spied, and fails if any argument holds the code, key bytes or message text (SC-008, FR-033).
- [x] T026 [P] Write `Web/src/theme/paper.css`: the Paper palette and corner radii from `Shared/UI/Paper.swift`, and the state tints from `Shared/UI/StateTint.swift`, as CSS variables under `prefers-color-scheme` light and dark (FR-020). No web fonts: the system font stack.
- [x] T027 (`Web/test/walk/cdp.mjs`; launch.sh serves the checkout's Web/dist on a free port and prints `WEB_URL`; smoke-tested with the real agents-control in headless Chrome 154: secure context, Paper ground, the 308, the page's own socket hears `hello`, no CSP violations) Walk tooling. Write `Web/test/walk/cdp.mjs`, a dependency-free CDP client on Node's built-in `WebSocket`, to:
  - launch and quit headless Chrome on a profile;
  - open a URL and set the viewport;
  - press by accessible name, type and paste;
  - take screenshots;
  - record `Network.requestWillBeSent` and console.

  Teach the run-app skill (`.agents/skills/run-app/SKILL.md` and its scripts) to start the scratch control plane with `--web <checkout>/Web/dist --web-port <free port>`, and to print the page's URL.

**Checkpoint**: `swift test` passes in ControlPlane, AgentsKit and WebTypes. `npm test` passes.
On a scratch root, `curl` sees the page at `http://localhost:<port>` with every header.

---

## Phase 4: User Story 1, pair a browser on this Mac (Priority: P1) 🎯 MVP gate

**Goal**: a browser pairs with a client code, reconnects with its key, and can be forgotten from
either side.

**Independent Test**: quickstart.md §2.

- [x] T028 (open to any grant through `ControlMethods.anyGrant`; the store's rule refuses a forget that would leave no operator, so a set-up needs one, which it always has) [US1] Add `clients/forgetSelf`:
  - a method constant in `Packages/AgentsKit/Sources/AgentsKitCore/Control/DaemonAPI+Control.swift`;
  - its handler in `ControlMethods`, which any paired client may call, forgets only the caller, and refuses `lastOperator`;
  - a reply before the close.

  Add a `WebSignatures` row, then regenerate (`scripts/web.sh types`).
- [x] T029 (`ReasonedClose`, adopted by the WebSocket transport and `PrefixReader`; `ControlRecords.wasForgotten`; one older test now expects `forgotten`, which the Remote already treats as `unknown`) [US1] Make `router.forgetClient` (`ControlRouter.swift`) close every session of the forgotten client with WebSocket close code 4403 and reason `forgotten`, on every copy (`clientForgotten` broadcast). Make a tombstoned client's next `auth` answer `refused: forgotten`. Test both in `ControlServiceTests`, with forgetting within 2 s (FR-014, SC-007).
- [x] T030 (frame E's words: "Ask for a new one"; walked in headless Chrome against the real agents-control) [US1] Build the pairing screen, `Web/src/views/Pairing.tsx` (frame E):
  - a paste field and nothing else;
  - the refusal words from contracts/browser-auth.md;
  - "This browser isn't supported", naming Safari and Chrome;
  - no private-window note: T002 found Chrome cannot tell one apart, so the how-to carries it;
  - no code in any URL;
  - focus on the field.
- [x] T031 (`session.ts` holds the page's state; walked: restart keeps the key, two tabs, Forget This Browser… clears IndexedDB, the other tab hears 4403) [US1] Build `Web/src/App.tsx`'s start-up:
  - no key: pairing;
  - a key: connect;
  - forgotten (4403, `refused`, or a `BroadcastChannel` from another tab): **This browser was forgotten** (frame F, second half), then delete the key and show pairing;
  - a wrong control plane: say so.

  Add **Forget This Browser…** with a confirmation, calling `clients/forgetSelf`. Until Phase 5 it sits on a bare paired page that lists hosts and projects as plain text, with the browser's name and grant.
- [x] T032 (a `browser` purpose on the window's CodeSheet: Device first and chosen, the browser's instructions) [P] [US1] In the Mac window's **Settings ▸ Control plane ▸ Clients** (`App/Sources/Control/ControlClientsPane.swift`), add **Pair a Browser…** beside **Pair a Mac…**. It has a grant choice defaulting to **Device**, and the code shown as text with **Copy** (frame E, right half). Browser rows show the kind's word and icon, the grant and last seen, and promote, demote and forget like the others (FR-012, FR-013).
- [x] T033 (a third target, A browser on this Mac, with its own Device/Operator choice; the QR code only for a phone) [P] [US1] In Agents Host's **Pair a Window or Phone…** sheet (`Host/Sources/HostWindow.swift` around line 295), add **A browser on this Mac**, with the same grant choice and copyable code (FR-012).
- [x] T034 (the bundle carries Web/dist as `Contents/Resources/dist`, since a folder reference keeps its name; a scratch Agents Host serves on 18792 or `AGENTS_HOST_WEB_PORT`, never 8792; `serveWebRemote` is optional so older saved settings still read; the container copy comes from scripts/build-linux-control.sh into the ignored deploy/web) [US1] Serve the page from Agents Host:
  - `Host/Sources/ControlLauncher.swift` passes `--web <bundle>/Contents/Resources/web --web-port 8792`, or `--no-web` when the new toggle is off;
  - the toggle **Serve Agents to browsers on this Mac** goes in `Host/Sources/HostWindow.swift`, stored in Agents Host's defaults (scoped by root, default on), and changing it restarts the control plane;
  - `project.yml` copies `Web/dist` into the AgentsHost target as `Resources/web`;
  - `deploy/Containerfile` copies it to `/usr/share/agents/web`, with no `--web-port`, so it is off.

  Run `xcodegen generate`, then build AgentsHost and AgentsStore one after the other (`-skipPackagePluginValidation`).
- [ ] T035 (walked in headless Chrome on /tmp/run-webus1, walks/us1.md: all seven scenarios pass, forgotten in 60 ms; Settings' calls made by walk/operator.mjs, since this session has no Accessibility permission; still to look at: the window's and Agents Host's sheets, waiting for the screen) [US1] Walk US1 (quickstart.md §1–§2) on a scratch root, in headless Chrome beside the scratch window. Cover:
  - the `curl` checks;
  - pairing as a device;
  - a restart on the same profile;
  - two tabs at once;
  - forgetting from Settings, then **Forget This Browser…**;
  - a spent code and an expired code;
  - promoting the browser to operator, which shows on its next connection (scenario 7).

  Record it in `specs/071-web-remote/walks/us1.md` with screenshots.

**Checkpoint**: US1's seven scenarios pass on scratch. The browser is a client like any other.

---

## Phase 5: The layout walk: US2's shell and US6, before any depth (plan Phase 4)

**Goal**: the three columns at every width, filled with real data, walked against frames A–F
while layout is cheap to change. Depth waits for Alex's look.

**Independent Test**: quickstart.md §3.

- [x] T036 (`route.ts`, `model.ts`, `views/Columns.tsx`, `Chat.tsx`; the identity line says "<browser> on this Mac", since a device can't read its own record's name) [US2] Build the shell in `Web/src/views/`:
  - `Columns.tsx`, with a hash router (`#/h/<host>/p/<project>/s/<session>`);
  - `ProjectsColumn.tsx`: every host's projects under host headings, from `hosts/list` and `projects/list` per host, with the browser's name, grant and **Forget This Browser…** at its foot (frame A);
  - `SessionsColumn.tsx`: sessions as a plain list, newest first, for now;
  - `Chat.tsx`: the transcript's text entries only, from `agents/turns` and `agents/transcript`, with the prompt drawn and disabled, pinned to the foot.
- [x] T037 [US6] Build the widths in `Web/src/views/Columns.tsx` and `paper.css`, as look/README.md's rules:
  - at least 1200: three columns, with the files pane's slot as a fourth column from 1440 and over the chat below that;
  - 760–1200: projects folded into a menu atop the sessions column, with the browser's identity in the ··· menu;
  - under 760: one column at a time, a back control, and `history` entries so the browser's Back moves between columns;
  - at every width, the prompt and the cards slot pinned and never covered (FR-019, US6).
- [x] T038 (and the link counts a hung control plane down at the missed heartbeat, rather than waiting on the close handshake) [P] [US7] Draw the two lost states as static views in `Web/src/views/Banner.tsx`, from frame F: **Can't reach the control plane**, with the columns greyed and the prompt disabled but holding its text; and **This browser was forgotten**. The connection logic comes in Phase 8.
- [x] T039 (walks/layout.md: every width and both F states, six fixes found and made) [US2] Rebuild `Web/dist`. Run the layout walk with `Web/test/walk/layout.mjs` (quickstart §3), on a scratch root seeded with 3 projects and 12 sessions, at 1600, 1440, 1000 and 390, plus both frame F states. Put each screenshot beside its frame in `specs/071-web-remote/walks/layout.md`, fix what differs, and walk again.
- [x] T040 (Alex, 2026-10-01: "Right, build depth") [US2] **Gate.** Ask Alex with the question tool to look at `walks/layout.md`. Depth starts when he says the layout is right. Make his changes here, before Phase 6.

**Checkpoint**: the layout matches frames A–F at every width, and Alex has looked.

---

## Phase 6: User Story 2, read and answer in three columns (Priority: P1)

**Goal**: sessions in the Mac window's groups, a live chat that reads as the Mac window's, and
permission and question cards answered from the browser.

**Independent Test**: quickstart.md §4.

- [x] T041 (ef117402; 9 files, run on every `swift test`; the row's words moved to `StatusShape.words` so the window and the fixtures share them) [US2] Write a fixture writer and `WebFixturesTests` in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/WebFixturesTests.swift`, as research R7. With `AGENTS_WRITE_WEB_FIXTURES=1` it writes the cases; without it, it re-runs the Swift rules on each input and fails on a difference. Cover, under `Tests/AgentsKitTests/Fixtures/web/`, each folder with a `README.md` naming the Swift function it pins:
  - `groups/`: every `AgentGroup` case and its order, parked order, needs-you count, and settled reports;
  - `status/`;
  - `turns/`: `TurnParts`, `TranscriptItem.display`, thoughts omitted, tool runs joined;
  - `background/`;
  - `labels/`;
  - `reducer/`: notification streams applied to an empty `AgentsModel`.
- [x] T042 (12 override samples; `shapes.test.mjs` also type-checks every fixture as its generated type with `tsc`, nested keys too) [US2] Make the fixture writer also write the override samples T020 needs. Add `Web/test/shapes.test.mjs`: every Swift-encoded object in the fixtures has exactly the keys that the generated `Shapes` gives its type.
- [x] T043 (75 cases) [P] [US2] Port `AgentGroup`, its order and `StatusShape` to `Web/src/model/groups.ts` and `status.ts`. Test them against `groups/` and `status/` in `Web/test/groups.test.mjs` (SC-005).
- [x] T044 (20 cases) [P] [US2] Port `TurnParts`, `TurnDetail` words and `TranscriptDisplay` to `Web/src/model/turns.ts`. Test against `turns/`.
- [x] T045 (`BackgroundWords` only: the daemon applies every update and sends `Agent.background` whole, so the web remote never applies one; `background/README.md` says so) [P] [US2] Port `BackgroundUpdate.applying`, `disconnecting` and `BackgroundWords` to `Web/src/model/background.ts`. Test against `background/`.
- [x] T046 (and `SessionLabelQuery`, which the search field uses) [P] [US2] Port `SessionLabelPolicy` to `Web/src/model/labels.ts`. Test against `labels/`.
- [x] T047 (`Work` is the reducer, `Store` adds the link; the front of a followed page is not trimmed yet) [US2] Port `AgentsModel.apply`, `refreshEverything`'s order and `heardSincePage` to `Web/src/model/store.ts`, with signals. Test against `reducer/`.
- [x] T048 (8 cases) [P] [US2] Write `Web/src/render/markdown.ts`, as research R9: markdown-it with `html: false`, rendered from tokens to Preact nodes; remote images replaced with a placeholder; links with `target=_blank rel="noopener noreferrer"`. Test in `Web/test/render.test.mjs` that `<script>`, `<img src=https://…>`, `javascript:` links and raw HTML render as text or placeholders (FR-031).
- [x] T049 (in `Columns.tsx` and `SessionRow.tsx`; archived listed when the fold opens, as the phone does) [US2] Fill the sessions column (`SessionsColumn.tsx`):
  - the groups in order, with their words, status shapes, labels and last activity, and only **Needs you** in colour (FR-018);
  - the workflows listed below them, as names only until US5;
  - archived sessions folded under **Archived sessions**.
- [x] T050 (`Chat.tsx` and `views/chat/Rows.tsx`) [US2] Fill the chat (`Chat.tsx` and `views/chat/`): concise turns, tool calls, plans, turn detail's Outcome, Steps and Details (069), and background-task rows (057), all live from `agent/entry` and `agent/changed`. Load long transcripts a page at a time, as the window does, and follow the end unless the person has scrolled up.
- [x] T051 [US2] Build the cards in `Web/src/views/Cards.tsx`: permission requests and question cards above the prompt, from `permissions/pending`, `elicitations/pending`, `agent/permission` and `agent/elicitation`. Answer with `permissions/answer` and `elicitations/answer`. When one is answered elsewhere, show it answered, and make its buttons do nothing (FR-024, scenario 5).
- [x] T052 (the fold was per client: now per session, folded per surface; the test is `aClientIsActiveWhileAnyOfItsSocketsIs` in `ControlRouterTests`, where the fold lives) [US2] Add presence and the title, as research R11: `presence/report` on visibility and focus, and `(N) Agents` from the needs-person count (FR-021, FR-022). Check that `ControlRouter`'s presence fold (lines 123–155) counts a client as active if any of its sessions is. If it does not, change it to fold per session, with a test in `ControlServiceTests` for two sockets of one client.
- [x] T053 (`walks/us2.md`: all six scenarios; median lag 1 ms against the window's wire; the scratch window itself not opened) [US2] Walk US2 (quickstart §4) with a real Claude turn on a scratch root: a question, then a permission, both answered in the browser. Measure the median update lag against the scratch window (SC-003). Record it in `walks/us2.md`.

**Checkpoint**: US2's six scenarios pass. The browser and the window agree on every group.

---

## Phase 7: User Story 3, send, start and steer (Priority: P1)

**Goal**: everything the first cut sends: prompts with attachments, Send now, the menus, a
new agent, session actions and labels.

**Independent Test**: quickstart.md §5.

- [x] T054 (files go as `browser:<name>`; a picture is shrunk with createImageBitmap and OffscreenCanvas) [US3] Build the prompt in `Web/src/views/Prompt.tsx`:
  - text, with attachments dropped, pasted or picked;
  - attachments encoded as the Remote sends them (`Remote/Sources/StartAgent/PhoneAttachments.swift`, `agents/prompt`), within the same size limits;
  - queued prompts shown, with **Send now** (`agents/sendNow`) and remove (`agents/unqueue`);
  - the draft kept per session in memory.
- [x] T055 (the runtime is chosen in the new-session form; `model/options.ts` is held to `options/drawable.json`) [P] [US3] Add the mode, model and runtime menus, from `agents/options`, `runtimes/list`, `options/remembered` and `modes/remembered`, set with `agents/setOption`, offering what the Mac window offers for that session (FR-025). Put them in `Web/src/views/PromptMenus.tsx`.
- [x] T056 (`WebSignatures` gains `agents/discardDraft`, `agents/draftOptions` and `modes/changed`) [US3] Build the new-agent flow in `Web/src/views/NewAgent.tsx`: the project folder, or a new or existing worktree (`worktrees/list`), with runtime, model, mode and first prompt, through `agents/start`, running on the project's host (FR-026). It opens from the sessions column's compose control.
- [x] T057 [P] [US3] Add session actions and labels: stop, park, unpark, archive and bring back (`agents/*`), from the session's ··· menu and the chat header; and labels with the ported `SessionLabelPolicy` and `agents/labelVocabulary`, set with `agents/setLabels` (FR-027). Put them in `Web/src/views/SessionMenu.tsx` and `Labels.tsx`.
- [x] T058 (`model/errors.ts` and the `Problem` strip in `Errors.tsx`) [US3] Handle a refusal by grant anywhere: `methodNotAllowed`, or the grant failure, shows "This browser's grant doesn't allow that", never a silent failure (spec edge case). Put it in `Web/src/views/Errors.tsx`.
- [x] T059 (`walks/us3.md`: all five steps, the window captured at each; found a host-side permission race after Stop) [US3] Rebuild `dist`, then walk US3 (quickstart §5) on scratch, with the scratch window showing each step. Record it in `walks/us3.md`.

**Checkpoint**: every P1 story passes. This is the first version worth having.

---

## Phase 8: User Story 7, the control plane goes away and comes back (Priority: P2)

This comes before US4 and US5, because Agents Host restarts on every ship (plan.md, Phases).

**Goal**: grey out, never blank; catch up by itself.

**Independent Test**: quickstart.md §6.

- [x] T060 (the page's link beats every 2 s and retries at most 4 s apart; the prompt stays typable while down) [US7] Wire `link.ts`'s states to the views: when the link is down, show **Can't reach the control plane** within 5 s, grey out the columns, disable sending and keep the drafts. On open, refresh everything, re-read the open transcript and pending cards, and enable sending again (FR-008, US7 scenarios 1–2).
- [x] T061 [P] [US7] When a host is offline (`control/hostChanged`, or a `hostOffline` failure), grey out that host's projects and say so, and leave the rest working (scenario 3).
- [x] T062 (`walks/us7.md`: banner 0.2 s, caught up 2.8 s after a minute away, no reload) [US7] Walk US7 (quickstart §6): stop the scratch control plane mid-turn for 60 s, then start it again. Measure detection and catch-up (SC-009). Record it in `walks/us7.md`.

---

## Phase 9: User Story 4, files, changes and live documents (Priority: P2)

**Goal**: review what an agent did, from the browser.

**Independent Test**: quickstart.md §7, first half.

- [x] T063 (paths are absolute, as the host requires; folders watched and re-listed) [US4] Build the files pane, `Web/src/views/FilesPane.tsx`:
  - `files/list` and `files/read`;
  - text in monospace and Markdown through `render/markdown.ts`;
  - pictures, and SVG only as `<img src=blob:>`;
  - HTML as source.

  It sits in the fourth column or over the chat, as T037 laid out (FR-029, FR-031).
- [x] T064 (edits without git hunks are line-diffed by `model/diff.ts`; neutral marks, as the window) [P] [US4] Build the changes view, `Web/src/views/Changes.tsx`, from `changes/list` and `changes/file`: per file, the diff as tinted lines.
- [x] T065 (`Passage` and `PassageMerge` ported and held to `page/` fixtures; the window's typing caret and line marks not yet) [US4] Add live documents: on `agent/showFile` for the open session, open the page beside the chat, `files/watch` it, and follow `files/changed`. Typing on it reaches the file through `artifact/write`, with the Mac window's merge rules (`Web/src/views/LiveDocument.tsx`).
- [x] T066 (`walks/us4.md`: all five scenarios; no console call or off-origin request from the hostile files) [US4] Walk US4 (quickstart §7): two files edited, a live page followed and typed on, and an `.html` and an `.svg` with a script that run nothing (CDP console and network). Record it in `walks/us4.md`.

---

## Phase 10: User Story 5, workflows: list and run now (Priority: P2)

**Goal**: the project's workflows under its sessions, and **Run Now**.

**Independent Test**: quickstart.md §7, second half.

- [x] T067 [US5] In `SessionsColumn.tsx`, list workflows (`workflows/list`) with their trigger, archived ones folded under **Archived workflows**, and **Run Now** (`workflows/run`). The new session appears under the project (FR-028).
- [x] T068 [US5] Walk US5 on scratch with a seeded workflow. Record it in `walks/us5.md`.

---

## Phase 11: Polish and cross-cutting concerns

- [x] T069 (5 new Swift cases, 1 widened; a render case; a lint rule; a log sink on Configuration) Security tests for every row of the spec's stolen-session table and FR-030 to FR-034 (SC-007). Audit T015, T016, T023, T025, T029 and T048 against the table, add any missing case, and write the mapping (row → test) to `specs/071-web-remote/walks/security.md`.
- [x] T070 (median 1.0–1.15 s settled, 3.2 s under load ~11; 89.8 KB gzipped) [P] Measure SC-004: seed 20 projects and 200 sessions, and time from navigation to the sessions column painted, in headless Chrome. Also record the gzipped bundle size (aim: under 150 KB). Put both in `walks/performance.md`.
- [ ] T071 Run the closing walk (quickstart §8) at 1440 in headless Chrome: SC-002's whole list, plus the SC-008 network and console capture. Then ask Alex with the question tool how Safari is walked (by him, or under the screen lease while he is away), and walk §2, §4 and §6 in Safari. Record it in `walks/closing.md`. Firefox is not walked (not installed).
- [x] T072 [P] Write the docs, from the spec's Docs section:
  - new: `docs/how-to/use-agents-in-a-browser.md`, which names Safari and Chrome as tested and says other computers wait on #61;
  - changed: `docs/how-to/connect-a-window-or-phone.md`, `docs/explanation/phone-and-ipad.md`, `docs/explanation/control-plane.md` and `README.md`. README also covers `Web/`, the checked-in build, `scripts/web.sh`, and that only changing the web app needs Node;
  - the `clients/forgetSelf` row in `specs/058-control-plane/contracts/control-api.md`.

  Run `scripts/docs.sh check`.
- [x] T073 (R1 fixed: ::1 taken leaves the listener off; R2 codes and R3 status open) Write a security review in `specs/071-web-remote/walks/security-review.md`: the listener, the `browser` kind, the origin binding, the CSP and rendering, and the stolen-session table, with what #42 must add when #61 serves the page publicly.
- [ ] T074 Compare six full suite runs against main on both commits (memory: the suite is flaky under load), and record the result in `walks/suite-compare.md`.
- [ ] T075 Final check:
  - `scripts/web.sh check`;
  - `swift test` in AgentsKit, ControlPlane and WebTypes;
  - `xcodegen generate`, then AgentsHost and AgentsStore built one after the other with `-skipPackagePluginValidation`;
  - `git status` clean apart from intended changes.

  Then tell Alex it is ready to merge. Merging is his call.

---

## Dependencies and execution order

```text
T001 → T002 ─┐
T003 ────────┼→ Phase 2 (T004–T010) → Phase 3 (T011–T027) → US1 (T028–T035)
             │                                              → Layout walk (T036–T040, gate: Alex looks)
             │                                              → US2 (T041–T053) → US3 (T054–T059)
             │                                              → US7 (T060–T062) → US4 (T063–T066)
             │                                              → US5 (T067–T068) → Polish (T069–T075)
```

- **T001 and T002 come first.** A failed check changes the origin, or stops the work.
- **T003** can run beside T001. Phase 4 needs it.
- **Within Phase 3:**
  - the listener (T011–T016) and the generator (T017–T021) are independent;
  - the wire client (T022–T025) needs T021's `generated.ts`, except for `keys.ts`;
  - T027 needs T013 and T014.
- **The layout walk (Phase 5)** needs US1, because the page must be paired to show real data.
  Phase 6 waits for T040, Alex's look.
- **US2 → US3.** US3's prompt sits in US2's chat.
- **US7, US4 and US5** each need only US2. They are ordered US7 first for the daily restarts,
  and could run in parallel by file.

## Parallel examples

- **Phase 2:** T004, T005, T006, T007 and T008 touch different files. T009 and T010 follow
  them.
- **Phase 3:** the listener lane (T011 → T012 → T013 → T014, then T015 ∥ T016) beside the
  generator lane (T017 → T018 → T019 → T020 → T021). Then T022 ∥ T023 ∥ T025 ∥ T026, then
  T024.
- **US1:** T032 (Mac window) ∥ T033 (Agents Host), beside T030 and T031 (web).
- **US2:** after T041 and T042, the ports T043 ∥ T044 ∥ T045 ∥ T046 ∥ T048. Then T047, then
  the views.
- **US3:** T055 ∥ T057 beside T054.

## Implementation strategy

1. **Prove the browsers first** (T001–T002). This is the cheapest place to find out that
   pairing has to change.
2. **MVP gate = US1.** A paired browser, and forgetting, with every refusal tested. It is the
   security core, and it is walkable alone.
3. **Layout before depth** (Phase 5). The three widths are walked against frames A–F in a real
   browser, with real data, and Alex looks before groups, turns and cards are built.
4. **US2 and US3** make the first version worth having. Stop there and ship it to Alex's look
   if time is short.
5. **US7, US4, US5**, then polish, security review and docs.
6. **Every phase** ends with a scratch walk and a rebuilt `Web/dist`. `scripts/web.sh check`
   passes at each commit, so the checked-in build never lags its source on the branch.
