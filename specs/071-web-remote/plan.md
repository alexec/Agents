# Implementation Plan: The Web Remote, First Version: a Browser on This Mac

**Branch**: `agents/write-spec-first-version` | **Date**: 2026-09-30 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/071-web-remote/spec.md` (#45). Look gate: frames
A–F in [look/](look/README.md), approved by Alex on 2026-09-30.

## Summary

`agents-control` gets a second listener, on loopback only, at `http://localhost:8792`. It
serves a static TypeScript web app and accepts that app's WebSocket at `/v1/connect`
(research R2, R3). The browser is one more client of the control plane:
- it makes a non-extractable P-256 key with WebCrypto and keeps it in IndexedDB (R4);
- it pairs with a client code as a new client kind, `browser`;
- it proves its key on every socket with 058's exchange, with the transcript bound to
  `http://localhost:8792` (R5);
- it then speaks 058's client wire, `{h, m}` lines, unchanged.

The web app's protocol types come from the Swift source. A Swift generator in a package of its
own reads `DaemonAPI`, the control types and the model types they reach, and writes one
TypeScript file. A Swift test fails when the checked-in file differs from a fresh generation
(R6). The rules the Mac window computes on the client (groups, status shapes, turn parts,
background words, labels) are ported by hand. Both sides test them against one set of JSON
fixtures (R7).

The built web app, `Web/dist/`, is checked in. Agents Host copies it into its bundle, so
building from source needs no Node. A manifest in `Web/dist/` records a hash of every source
input, and a Swift test with no Node checks that hash against the tree. CI also rebuilds the
app with Node and fails on any byte of difference (R8).

The work is ordered so the layout can be walked early:
1. a spike on the three browsers (R1);
2. the listener, the generator and pairing;
3. the three columns at every width, filled with real projects and sessions and a plain chat,
   walked in a real browser against frames A–F;
4. only then the depth: groups, concise turns, cards, sending, files, workflows, reconnect.

## Technical Context

**Language/Version**:
- Swift 6.2 with strict concurrency, as in the rest of the repository, for the listener, the
  generator and the shared fixtures.
- TypeScript 5.x, `strict`, for the web app, compiled to ES2022 modules.

**Primary Dependencies**:
- *Listener:* swift-nio (`NIOHTTP1`, `NIOWebSocket`, `NIOPosix`), already used by
  `agents-control` (`ControlWebSocketServer` in `Packages/AgentsKit/Sources/ControlDial/ControlDial.swift`).
  Nothing new.
- *Generator:* swift-syntax (`SwiftParser`, `SwiftSyntax`), in a new package
  `Packages/WebTypes` so that neither `AgentsKit` nor the apps link it.
- *Web app*, kept small on purpose, every version pinned exactly in `package-lock.json` (R9):
  - `preact` and `@preact/signals` for the views;
  - `markdown-it` with `html: false` for agent text and Markdown files;
  - `esbuild` to build, and `typescript` for `tsc --noEmit` only.
  - Tests run under `node --test` on bundles esbuild makes, so there is no test framework to
    pull in.
- *Browser APIs:* WebCrypto (ECDH P-256, HKDF-SHA256, HMAC-SHA256), IndexedDB, WebSocket,
  `navigator.storage`, and the Page Visibility and focus events for presence.

**Storage**:
- *Browser:* one IndexedDB database, `agents`, with one store, `key`. It holds the
  non-extractable `CryptoKey` pair, the client id and the control plane's public key. Nothing
  goes in local storage, session storage or cookies (FR-009).
- *Control plane:* `ClientRecord` with `kind: browser` in the existing store, with no layout
  change.

**Testing**:
- `swift test` in `Packages/ControlPlane` covers the listener (Host, Origin, CSP, redirects,
  traversal, refusals), the origin-bound exchange, `clients/forgetSelf` and forgetting.
- `swift test` in `Packages/AgentsKit` covers the shared fixtures, as the Swift side, and the
  `Web/dist` manifest hash.
- `swift test` in `Packages/WebTypes` covers the generator, and that the checked-in
  `generated.ts` is fresh.
- `npm test` in `Web/` covers the TypeScript side of the fixtures, the WebCrypto exchange
  against vectors from `ControlAgreement`, the wire client, and rendering safety (no raw HTML,
  no remote images).
- The walks:
  - the run-app skill, on a scratch root with Agents Host's scratch build;
  - headless Chrome over the DevTools protocol, with a throwaway profile, for every walk
    (Alex's choice, R10);
  - Safari by hand, or under the screen lease with Alex's go-ahead, only in the spike and the
    closing walk;
  - Firefox is not installed, and is not tested in this version.

**Target Platform**:
- macOS 27, with Agents Host's single copy serving the page.
- The current Safari, Chrome and Firefox on macOS, on the same Mac.
- The container's `agents-control` carries the files, but the listener is off by default.

**Project Type**: a static web app served by an existing Swift service, plus a code-generation
package and small changes to the control plane, the Mac window and Agents Host.

**Performance Goals**:
- **SC-003:** an update reaches the browser at most 0.5 s after the Mac window, at the median.
- **SC-004:** usable within 2 s with 20 projects and 200 sessions. The bundle aims for under
  150 KB gzipped, so the page is quick to load on localhost.
- **SC-009:** caught up within 5 s of the control plane's return.
- **FR-014:** a forgotten browser is cut off within 2 s.
- **Long transcripts:** a chat of thousands of lines stays responsive. It is windowed in pages
  from `agents/turns` and `agents/transcript`, as the Mac window does.

**Constraints**:
- loopback only: the listener binds `127.0.0.1` and `::1`;
- every call is judged by the client's grant, so the web app uses only methods the `device`
  grant allows (FR-016);
- no secret in any URL, log or console;
- no request to any other origin;
- building from source needs no Node.

**Scale/Scope**: one person, one Mac, about 3 browsers, up to 20 hosts, 20 projects and 200
sessions.

## Constitution Check

*Gate before Phase 0; re-checked after Phase 1.* The constitution is
[.specify/memory/constitution.md](../../.specify/memory/constitution.md) v1.2.1. The working rules
from AGENTS.md and memory are added in brief.

| Rule | How this plan meets it | Result |
|---|---|---|
| I. Spec-led | Spec 071 has its acceptance criteria and clarifications, and the look gate was approved | Pass |
| II. Capability-driven runtimes | The browser starts and drives agents only through the host's existing methods. It never names a runtime vendor, and its runtime, model and mode menus come from `agents/options` and `runtimes/list` | Pass |
| III. Scoped access and user control | Permission requests and questions are answered through the app's own cards (`permissions/answer`, `elicitations/answer`). The browser cannot reach a host except through the grant checks at the control plane and again at the host. `files/write` and `files/browse` stay operator-only and unused | Pass |
| IV. Work is inspectable | The browser shows the same turns, tool calls, steps, details, changes and files as the Mac window | Pass |
| V. Docs and quality travel with the feature | The spec's Docs section is a task. Warnings stay errors in Swift, and `tsc --strict` runs with `noUnusedLocals`. Generated artifacts (`generated.ts` and `Web/dist`) have freshness checks, which is what Principle V asks for | Pass |
| Project constraint: generated files from their source of truth | `generated.ts` is changed only by the generator, and `Web/dist` only by `npm run build`. Both are checked | Pass |
| Settle the UX before depth | Frames A–F are approved. Phase 4 walks the layout in a real browser, against the frames, before any depth is built | Pass |
| Walk what you ship | Each story ends with a scratch walk recorded in `walks/` | Pass |
| Scratch roots only; never the real daemon or devices | Every walk uses a scratch root and the scratch Agents Host, on a scratch port (`AGENTS_CONTROL_WEB_PORT`) so the live 8792 is untouched. The browser uses its own profile where the browser allows it (R10) | Pass |
| Security review before merge | A new listener, a new client kind and a page that can run commands through a grant. Phase 10 has a review against the stolen-session table | Pass |

Re-checked after design: no change.

## Project Structure

### Documentation (this feature)

```text
specs/071-web-remote/
├── spec.md
├── plan.md              # this file
├── research.md          # R1–R12
├── data-model.md        # browser key, client kind, listener config, generated types, fixtures
├── quickstart.md        # the scratch walks
├── contracts/
│   ├── loopback-listener.md   # endpoints, Host/Origin rules, headers, CSP
│   ├── browser-auth.md        # the exchange from the browser, codes, forgetSelf, close reasons
│   └── generated-types.md     # what is generated, from where, how drift fails
├── spikes/s1-browsers/  # the T001 spike page and its results
├── look/                # frames A–F (approved)
├── walks/               # one record per walk
└── tasks.md
```

### Source Code (repository root)

```text
Web/                                    # NEW: the web remote
├── package.json, package-lock.json     # exact versions; scripts: build, check, test
├── .node-version                       # the one Node version the build is made with
├── tsconfig.json                       # strict
├── build.mjs                           # esbuild: deterministic, no hashes in names, writes the manifest
├── src/
│   ├── protocol/generated.ts           # GENERATED by Packages/WebTypes, checked in
│   ├── protocol/methods.ts             # typed call(method, params) over generated.ts
│   ├── wire/auth.ts                    # hello/auth/ok, from the browser (contracts/browser-auth.md)
│   ├── wire/keys.ts                    # WebCrypto key, IndexedDB, HKDF/HMAC
│   ├── wire/link.ts                    # one socket per tab, {h, m} lines, backoff, catch-up
│   ├── model/                          # ports of AgentGroup, StatusShape, TurnParts,
│   │                                   #   TranscriptDisplay, BackgroundWords, SessionLabelPolicy,
│   │                                   #   and the AgentsModel reducer
│   ├── views/                          # columns, chat, cards, prompt, files pane, pairing, banners
│   ├── render/markdown.ts              # markdown-it, html:false, no remote images, safe links
│   └── theme/paper.css                 # the Paper palette from Shared/UI/Paper.swift and StateTint
├── test/                               # node --test: fixtures, crypto vectors, wire, rendering
└── dist/                               # BUILT, checked in: index.html, app.js, app.css, MANIFEST

Packages/WebTypes/                      # NEW package: the generator (swift-syntax)
├── Package.swift
├── Sources/WebTypesKit/                # parse, resolve, emit TypeScript
├── Sources/agents-webtypes/main.swift  # `swift run agents-webtypes [--check]`
└── Tests/WebTypesTests/                # emitter cases + GeneratedIsFreshTests

Packages/AgentsKit/Sources/AgentsKitCore/
├── Control/Grant.swift                 # ClientRecord.Kind + .browser
├── Control/ControlAuth.swift           # origin passed per listener (unchanged algorithm)
├── Daemon/DaemonAPI+Web.swift          # NEW: WebSignatures, the method → (params, result) table
└── Control/DaemonAPI+Control.swift     # + clients/forgetSelf
Packages/AgentsKit/Tests/AgentsKitTests/
├── Fixtures/web/                       # NEW: shared fixtures (groups, turns, background, labels, reducer)
├── Unit/WebFixturesTests.swift         # NEW: the Swift side of every fixture
└── Unit/WebDistManifestTests.swift     # NEW: Web/dist/MANIFEST matches Web/ sources

Packages/ControlPlane/Sources/ControlPlaneKit/
├── Server/LoopbackListener.swift       # NEW: second ServerBootstrap, 127.0.0.1 + ::1
├── Server/StaticFiles.swift            # NEW: Web/dist served with fixed headers (contracts/loopback-listener.md)
├── ControlService.swift                # accept(origin:) per listener; forgetSelf; browser naming
└── ControlRouter / Methods             # clients/forgetSelf; per-session presence fold check
Packages/ControlPlane/Sources/agents-control/main.swift   # --web DIR, --web-port N, --no-web
Packages/AgentsKit/Sources/ControlDial/ControlDial.swift  # upgrader hook for Host/Origin checks

Host/Sources/ControlLauncher.swift      # passes --web <bundle>/Resources/web --web-port 8792
Host/Sources/…                          # "A browser on this Mac" in Pair a Window or Phone…; the web toggle
App/Sources/Settings/…ControlPlane…     # Clients ▸ Pair a Browser…; browser rows
project.yml                             # AgentsHost: copy Web/dist → Resources/web
deploy/Containerfile                    # copies Web/dist; listener stays off unless --web-port
.github/workflows/ci.yml                # + ControlPlane and WebTypes tests; + a web job (Node)
scripts/web.sh                          # build | check | test | serve-scratch
docs/…                                  # the spec's Docs section
```

**Structure Decision**:
- *`Web/` sits at the root, beside `App/`, `Host/` and `Remote/`,* because it is a fourth
  client, not part of a Swift package.
- *The generator has a package of its own,* so swift-syntax, which is large and slow to build,
  is never in the apps' or the hosts' dependency graph.
- *`WebSignatures` lives in `AgentsKitCore`,* beside the methods it names. It is plain Swift
  (`(String, Any.Type, Any.Type)` rows), so renaming a type breaks the build there before the
  generator runs.

## What T106 leaves, which this plan assumes

The plan is written as if 058 T106 and T042 have landed (they are being removed on
`agents/do-058-s-t106`). This means:
- `Bridge/`, `DirectLink`, `SocketLink` spawning, `HostSet`, the `AGENTS_STORE` compile
  condition and the Remote's TLS-PSK path (`LinkTLS`, `AwayLink`, `agents-lan-v1`) are gone;
- the Mac window is the store build, a client of the control plane;
- the TLS listener on 8791 is the control plane's only other door.

Nothing here touches the removed code. The only other changes are to:
- `ControlService`, `ControlDial`'s WebSocket server and `ControlAuth.origin`;
- `ClientRecord.Kind` and the control methods;
- the Mac window's Clients page and Agents Host's pairing sheet.

If T106 has not merged when this branch starts, it rebases onto it first. The listener lives in
the control plane, which T106 does not touch.

## Phases

Each phase ends with a check, and every phase from 3 on ends with a walk in `walks/`.

0. **Spike S1, the browsers** (R1). Do Safari, Chrome and Firefox treat `http://localhost` as
   a secure context? Do they keep a non-extractable P-256 key in IndexedDB across a full quit
   and restart, and run ECDH, HKDF and HMAC so that their output matches `ControlAgreement`'s
   vectors? R1 plans each outcome. Nothing else starts until the spike is written up.
1. **Setup**: the `Web/` skeleton with a deterministic build, the manifest and its Swift check,
   `Packages/WebTypes` with an empty emitter, `scripts/web.sh`, and the CI job.
2. **Foundational**:
   - the loopback listener (static files, headers, Host and Origin rules, the redirect, the
     upgrade);
   - the exchange bound to its origin;
   - `ClientRecord.Kind.browser`;
   - `WebSignatures`, the generator and the first `generated.ts` with its freshness test;
   - the web app's wire client (keys, auth, link).
3. **US1, pairing** (MVP gate):
   - the pairing screen;
   - **Pair a Browser…** in the Mac window and **A browser on this Mac** in Agents Host;
   - `clients/forgetSelf`, and closing on forget.

   Walk it in Safari on a scratch root.
4. **The layout walk** (US2 shell and US6), before any depth:
   - the three columns, real projects under their hosts, sessions listed (by plain recency for
     now), a plain-text chat and the prompt drawn;
   - the medium and narrow widths and the files pane's place;
   - the forgotten and can't-reach banners as static states.

   Walk at 1440, 1600, 1000 and 390 against frames A–F, and screenshot each beside its frame.
   Fix the layout here, while it is cheap. Alex looks at the screenshots before Phase 5.
5. **US2 depth**: the shared fixtures with groups and order, the reducer, concise turns, turn
   detail, background tasks, permission and question cards, and live updates. Walk with a real
   Claude turn.
6. **US3, sending**: the prompt with attachments, **Send now**, the mode, model and runtime
   menus, starting an agent in a folder or a worktree, stop, park, unpark, archive, bring back,
   and labels.
7. **US7, reconnect**: backoff, greying out, keeping the draft, catching up, and hosts going
   offline.
8. **US4, files**: the files pane, the changes view, a live document typed on, and safe
   rendering of HTML and SVG.
9. **US5, workflows**: the list with archived workflows folded, and **Run Now**.
10. **Polish**:
    - security tests for each row of the stolen-session table;
    - SC-003, SC-004 and SC-009 measured;
    - the closing walk in all three browsers;
    - the docs;
    - the security review;
    - a six-run suite comparison against main.

US7 comes before US4 and US5, though all three are P2: Agents Host restarts on every ship, so
a page that cannot reconnect would get in the way of every later walk.

## Complexity Tracking

| Choice | Why needed | Simpler alternative rejected because |
|---|---|---|
| A second listener, plain HTTP on loopback | Browsers need a secure context and a certificate they trust. Only `localhost` gives both without #61 | Serving on 8791 needs the browser to accept a self-signed certificate, which a browser warns about, and a pin it cannot check |
| A swift-syntax generator in its own package | FR-035: types that cannot drift. `DaemonAPI` has about 250 hand-written Codable types, and nothing ties a method to its types | Hand-written TypeScript types drift by definition. JSON Schema from Swift needs the same parsing and then a second generator. Runtime reflection cannot see a type without an instance |
| A method table (`WebSignatures`) | Nothing in Swift links a method to its params and result. The generator needs that link, and FR-016 needs the list of what the web app calls | Parsing doc comments for the link is fragile, and would not compile-check the types |
| Checked-in `Web/dist` with a manifest and a CI rebuild | D7: building from source needs no Node | Building in Xcode would need Node for every build. A release-only download would leave developers without a web remote |
| Hand-ported client rules with shared fixtures | D5/D6: SwiftWasm is rejected | Moving every rule to the host as a new method would change the Mac window and the Remote too, for no gain in this version |

## Decisions taken with Alex while planning (2026-09-30)

- **Browsers: "Safari only for now".** The question was asked believing Chrome was missing too.
  Chrome is in fact installed, so the spike covers Safari and Chrome, and Firefox (not
  installed) stays untested (R1).
- **Walks: headless Chrome**, not `safaridriver`. Safari is checked by hand in the spike and in
  the closing walk (R10).

## Still open

- Whether the Agents Host toggle **Serve Agents to browsers on this Mac** wants a frame of its
  own in `look/` (R2). The plan treats it as a plain checkbox in the existing window.
- Firefox, until it is installed and the spike page re-run.
