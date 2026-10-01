# Feature Specification: The Web Remote, First Version: a Browser on This Mac

**Feature Branch**: `agents/write-spec-first-version`

**Created**: 2026-09-30

**Status**: Draft

**Issue**: [#45](https://github.com/alexec/Agents/issues/45) Web remote: the desktop app in a
browser. Depends on [058](../058-control-plane/spec.md) (the control plane). Use from other
computers waits on [#61](https://github.com/alexec/Agents/issues/61) (a public certificate).
The security review for the open internet is [#42](https://github.com/alexec/Agents/issues/42).

**Input**: Write the spec for the first version of #45: the web remote, for a browser on this
Mac (`localhost`), as a client of the 058 control plane. It talks to the control plane's
WebSocket protocol only, never to the phone bridge or `DirectLink`, which 058 T106 removes.

## Why this feature exists

The Mac window, the iPhone and the iPad are windows onto agents that run on hosts. Since 058,
each of them is a client of the control plane: it pairs with a code, holds a key, and is given
a grant. A browser can be one more client. Nothing runs in it. An agent started or answered
from the browser shows up in the Mac window as if it had been started there.

#45 wants the web remote for any computer, with nothing to install. That needs a certificate a
browser trusts, which is #61. This first version does not wait for it. Browsers treat
`http://localhost` as a secure context, so a web remote served by the control plane on this
Mac, to a browser on this Mac, needs no certificate. That is enough to build and walk:
- the three-column layout;
- the protocol types, generated from the Swift source so they can't drift;
- pairing a browser with a key it can't export.

When #61 lands, the same web app is served from the control plane's public address and the
browser dials `wss://`. Nothing in this spec should need redoing for that, except the
listener and the origin it accepts.

## Decisions

These settle #45's design questions for the first version.

**D1 · Transport.** The web remote is a client of the control plane, and only of the control
plane. It speaks 058's wire ([contracts/wire.md](../058-control-plane/contracts/wire.md)): the
`hello`/`auth`/`ok` exchange, then one JSON line per WebSocket message, `{h, m}` both ways. It
never reaches a host, the phone bridge, `DirectLink` or a daemon socket.

**D2 · Serving.** `agents-control` serves the web app and its WebSocket from a second listener
of its own:
- bound to the loopback addresses only (`127.0.0.1` and `::1`), never to the network;
- plain HTTP and plain WebSocket (`http://localhost:<port>`, `ws://localhost:<port>/v1/connect`);
- on a fixed port of its own, chosen in the plan, beside the TLS listener on 8791, which is
  unchanged;
- on in the single copy that Agents Host runs, and off by default in the container.

The canonical address is `http://localhost:<port>`. A request for `127.0.0.1` or `[::1]`
redirects there, so the browser keeps one origin and one key.

**D3 · Certificates.** None in this version. A browser on another computer cannot use the web
remote until #61 gives the control plane a publicly trusted certificate. A tunnel (Tailscale or
Cloudflare Tunnel) is the fallback #61 names, and is also out of scope here.

**D4 · Pairing a browser.** The browser makes a P-256 key with WebCrypto, marked
non-extractable, and keeps it in IndexedDB. It pairs with a client code like any other client,
and proves its key on every connection with 058's exchange (R6), deriving the client key with
ECDH and HKDF as `ControlAgreement` does. The control plane records it as a client of a new
kind, `browser`.

**D5 · Stack.** The web app is TypeScript, built to static files with no server code. Its
protocol types (requests, results, notifications, records, failures) are generated from
`DaemonAPI` and the control types in `AgentsKitCore`. The generated file is checked in, and the
build fails when it differs from what the Swift source would generate now. Rules the Mac window
computes on the client, such as which group an agent sits in, are ported by hand and tested
against shared fixtures that the Swift tests also run.

**D6 · SwiftWasm: rejected for this version.** It would share only the protocol types and some
view logic, because the UI is SwiftUI and must be written again for the web either way. The
types are what D5's generator already covers. In exchange it would cost:
- a large download: Foundation alone makes a WebAssembly bundle of many megabytes, against a
  small TypeScript bundle;
- a second toolchain in the build and in CI;
- WebCrypto, IndexedDB and WebSocket reached only through JavaScript glue, which is exactly
  where the security-sensitive code lives;
- `AgentsKitCore` code that assumes CryptoKit or Darwin, which would need to be cut apart.

If hand-ported view logic drifts in practice despite the fixtures, a spike can revisit SwiftWasm
for that logic alone.

**D7 · The built bundle is checked in.** Node is needed only to change the web app. Its built
static files are checked in, as the generated types are, and CI fails when they differ from a
fresh build. Building the Mac app and Agents Host from source needs no Node.

## Clarifications

### Session 2026-09-30

- Q: Should Agents Host serve the web remote on localhost by default? → A: On by default.
- Q: How should the web app's build fit into building from source? → A: Check in the built
  bundle; CI checks it is fresh (D7).
- Q: Should a focused browser tab count as the person being present, like the Mac window? →
  A: Yes, like the window (FR-022).
- Q: Do the wireframes A–F pass the look gate? → A: Approved by Alex, 2026-09-30.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Pair a browser on this Mac (Priority: P1)

The person opens Agents in a browser on the Mac that runs Agents Host, at
`http://localhost:<port>`. With no key yet, the page asks for a code and shows nothing else.
The person gets a code from the Mac window (**Settings ▸ Control plane ▸ Clients ▸ Pair a
Browser…**) or from Agents Host (**Pair a Window or Phone…**, then **A browser on this Mac**),
choosing **Device** or **Operator**. They paste it. The browser is paired, lists every host's
projects, and from then on connects by itself.

**Why this priority**: Nothing else in the browser works until it is a paired client, and
pairing is where the security of the whole feature is decided.

**Independent Test**: On a scratch root with Agents Host's scratch build running, open the page
in a real browser, pair it with a device code, and see the projects listed. Reload, quit and
reopen the browser: it connects without a code. Forget it in the scratch window's Settings: the
page says so at once and asks for a code again.

**Acceptance Scenarios**:

1. **Given** a browser with no key, **When** it opens the page, **Then** it shows only the
   pairing screen, and sends nothing to the control plane but the exchange a code needs.
2. **Given** a valid client code, **When** it is pasted, **Then** the browser makes its key,
   announces it, and is listed under **Clients** as a browser with the grant the code was
   issued with.
3. **Given** a code that is wrong, spent, expired or from another control plane, **When** it is
   pasted, **Then** the page says which, and keeps no key.
4. **Given** a paired browser, **When** the page is reloaded or the browser restarted, **Then**
   it reconnects with its key, with no code.
5. **Given** a paired browser, **When** the person forgets it in Settings, **Then** its socket
   closes within 2 seconds, the page says **This browser was forgotten**, deletes its key, and
   shows the pairing screen.
6. **Given** a paired browser, **When** the person chooses **Forget This Browser** in the web
   remote, **Then** the control plane forgets it and the page deletes its key.
7. **Given** a browser paired as a device, **When** the person changes it to operator in
   Settings, **Then** its next call is judged by the new grant, without pairing again.

---

### User Story 2 - Read and answer agents in three columns (Priority: P1)

A paired browser shows the Mac window's layout: projects on the left, then the chosen project's
sessions, then the chosen session's chat. Sessions are grouped as in the Mac window, in the same
order and with the same words. The chat is live: concise turns, tool calls, plans, turn detail
and background tasks. Permission requests and question cards appear above the prompt, and
answering one in the browser answers it everywhere.

**Why this priority**: Watching and answering is what a remote is for; it is the smallest
version worth having.

**Independent Test**: Against a scratch root, start a real Claude turn from the scratch Mac
window that asks a question and then asks permission to run a command. Open the same session in
the browser. Answer both in the browser. The Mac window shows the answers, the turn carries on,
and the browser's chat matches the Mac window's.

**Acceptance Scenarios**:

1. **Given** hosts with projects, **When** the browser connects, **Then** it lists every host's
   projects under their host's heading, as the Mac window does.
2. **Given** a project, **When** it is chosen, **Then** its sessions are listed in the Mac
   window's groups and order, each with its status, labels and last activity, and its
   workflows are listed under them.
3. **Given** an agent working, **When** its session is open, **Then** each update appears in the
   browser no more than half a second after it appears in the Mac window.
4. **Given** a permission request or a question card, **When** it is answered in the browser,
   **Then** the agent carries on, and every other client shows it answered.
5. **Given** the same request answered in the Mac window first, **When** the browser is showing
   it, **Then** the browser shows it answered and its buttons do nothing.
6. **Given** a finished turn, **Then** its concise view, its steps and its details read as they
   do in the Mac window (069).

---

### User Story 3 - Send, start and steer from the browser (Priority: P1)

From the browser the person sends a prompt, with attachments; uses **Send now** on a queued
prompt; changes the mode, model and runtime; starts a new agent in the project folder or in a
worktree; and stops, parks, unparks, archives and brings back agents.

**Why this priority**: Without sending, the browser is only a viewer.

**Independent Test**: In the browser on a scratch root, start an agent in a new worktree with a
picture attached, queue a second prompt while it works and press **Send now**, change its model,
then park it, unpark it, stop it and archive it. The scratch Mac window shows each step as it
happens.

**Acceptance Scenarios**:

1. **Given** a project, **When** the person starts an agent with a prompt, **Then** it runs on
   that project's host, in the folder or worktree chosen, with the runtime, model and mode
   chosen.
2. **Given** a file dropped on, pasted into, or picked for the prompt, **Then** it is sent with
   the prompt as the Remote sends attachments today.
3. **Given** a turn in progress, **When** a prompt is sent, **Then** it waits as a queued prompt,
   and **Send now** on it steers the turn as in the Mac window.
4. **Given** a session, **When** the person stops, parks, unparks, archives or brings it back,
   **Then** it moves to the same group it would from the Mac window.
5. **Given** a session's labels, **When** the person adds or removes one, **Then** every client
   shows the change.

---

### User Story 4 - Files, changes and live documents (Priority: P2)

The person opens the files an agent touched, the changes view (what the agent changed, file by
file, as a diff), and a live document the agent is writing, which follows the agent's edits and
can be typed on.

**Why this priority**: Reviewing what an agent did is the next most common thing after
answering it, but a first version is usable without it.

**Independent Test**: In the browser on a scratch root, run a turn that edits two files and
calls `show_file` on a Markdown page it then writes. The changes view lists both files with
diffs. The live page opens on its own and follows each edit. Typing on it reaches the file.

**Acceptance Scenarios**:

1. **Given** a session, **When** the files pane is opened, **Then** it lists the agent's files
   and opens one as text, Markdown or a picture.
2. **Given** an agent that changed files, **When** the changes view is opened, **Then** it lists
   them with their diffs, as in the Mac window.
3. **Given** an agent calls `show_file` on a Markdown page, **When** its session is open in the
   browser, **Then** the page opens beside the chat and follows each write.
4. **Given** a live page, **When** the person types on it, **Then** the text reaches the file on
   the host.
5. **Given** an HTML or SVG file, **When** it is opened, **Then** HTML shows as source and SVG
   as a picture; neither runs any script.

---

### User Story 5 - Workflows: list and run now (Priority: P2)

Under a project's sessions, the browser lists its workflows, and the person can run one now.

**Why this priority**: Small, and in #45's first cut, but the least used of it.

**Independent Test**: On a scratch root with one workflow, run it from the browser. Its session
appears in the browser and the Mac window.

**Acceptance Scenarios**:

1. **Given** a project with workflows, **Then** the browser lists them with their trigger, and
   archived ones folded away, as in the Mac window.
2. **Given** a workflow, **When** the person chooses **Run Now**, **Then** it runs, and its
   session appears under the project.

---

### User Story 6 - Desktop and narrow widths (Priority: P2)

The page shows three columns when the window is wide, and fewer when it is narrow. At phone
width it shows one column at a time, in the iPhone Remote's order: projects, then sessions, then
the chat, with a way back.

**Why this priority**: Browser windows are resized freely; a layout that breaks when narrowed
makes the first version feel broken.

**Independent Test**: Resize the browser through the widths in the look gate's frames, on a
scratch root with a session open. Every frame's layout appears at its width, and nothing is cut
off or overlaps.

**Acceptance Scenarios**:

1. **Given** a window at least 1200 points wide, **Then** all three columns show, and the files
   pane opens as a fourth column beside the chat when there is room for it, otherwise over the
   chat.
2. **Given** a window between 760 and 1200 points wide, **Then** the projects column folds into a
   menu at the top of the sessions column, and the sessions and chat columns show.
3. **Given** a window narrower than 760 points, **Then** one column shows at a time, with a back
   control, and the browser's own Back moves between them.
4. **Given** any width, **Then** the prompt and the cards above it are never hidden behind
   anything.

---

### User Story 7 - The control plane goes away and comes back (Priority: P2)

When Agents Host or its control plane stops, the browser says so and keeps what it last showed,
greyed out. When the control plane returns, the browser reconnects by itself and catches up.

**Why this priority**: Agents Host restarts on every ship. A page that goes blank, or has to be
reloaded, would be noticed daily.

**Independent Test**: With a session open in the browser on a scratch root, stop the scratch
Agents Host mid-turn for a minute, then start it again. The page shows **Can't reach the control
plane** while it is down, and catches up within 5 seconds of its return without a reload.

**Acceptance Scenarios**:

1. **Given** the control plane stops, **Then** within 5 seconds the page shows **Can't reach the
   control plane**, keeps the projects and the open chat greyed out, and disables sending.
2. **Given** it returns, **Then** the page reconnects within 5 seconds, re-reads what it missed,
   and enables sending again, with nothing typed in the prompt lost.
3. **Given** a host goes offline, **Then** that host's projects are greyed out and say so, and
   the rest keep working.

---

### Edge Cases

- **The page opened at `127.0.0.1` or `[::1]`.** It is redirected to `http://localhost:<port>`,
  so the browser never holds two keys for one control plane.
- **The browser clears its site data.** The key is gone. The page shows the pairing screen; the
  old record stays under **Clients**, last seen when it was cleared, until it is forgotten.
- **A private window.** It can pair, and its key is lost when the window closes. The pairing
  screen says so when the browser reports storage that won't last.
- **Two tabs of one browser.** Both work at once, on the one key, and neither cuts the other off.
- **Two different browsers on this Mac.** Each pairs separately and is its own client.
- **A code from a control plane on another machine.** It is refused with **This code is for
  another control plane**: the browser can reach only the control plane that served the page.
- **The browser's storage refuses a non-extractable key** (an old or unusual browser). The page
  says the browser isn't supported and names the supported ones; it never falls back to a key it
  could export.
- **A forgotten browser that was offline.** Its next connection is refused as forgotten; it
  deletes its key and shows the pairing screen.
- **Agents Host is not running.** Nothing serves the page; the browser shows its own error. The
  how-to says to open Agents Host.
- **An operator-only action in a device-grant browser.** The first version offers none. If a
  call is refused all the same, the page says the grant doesn't allow it, rather than failing
  silently.
- **A turn with thousands of updates, or a transcript of thousands of lines.** The page stays
  responsive and keeps the chat following the end as the Mac window does.
- **Agent text containing HTML, scripts or remote images.** It shows as text. Nothing in an
  agent's output runs or loads anything (FR-031).

## Requirements *(mandatory)*

### Functional Requirements

**Serving and transport**

- **FR-001**: The control plane MUST serve the web app's static files and accept the web
  remote's WebSocket on a listener bound only to the loopback addresses. It MUST NOT be reachable
  from another machine.
- **FR-002**: The listener MUST be on by default in the single copy Agents Host runs, with no
  step from the person, MUST be off by default in the container, and MUST be able to be turned
  off.
- **FR-003**: The listener MUST answer only `GET` for the web app's files and the upgrade at
  `/v1/connect`. It MUST have no other endpoint, and no endpoint that changes anything.
- **FR-004**: A request whose `Host` is not `localhost`, `127.0.0.1` or `[::1]` with the
  listener's port MUST be refused. `127.0.0.1` and `[::1]` MUST be redirected to `localhost`.
  This defeats DNS rebinding.
- **FR-005**: A WebSocket upgrade MUST be refused unless its `Origin` is exactly the listener's
  canonical origin, `http://localhost:<port>`. An upgrade with no `Origin` MUST be refused on
  this listener.
- **FR-006**: The control plane MUST bind the key exchange on this listener to the listener's
  canonical origin, so a proof made here works nowhere else, and a proof made for its TLS
  address does not work here.
- **FR-007**: After the exchange, the browser MUST speak 058's client wire unchanged: every call
  is judged by the client's grant, at the control plane and again at the host.
- **FR-008**: The browser MUST reconnect by itself, with backoff, after the socket drops, and
  MUST re-read what it missed, as the Mac window does.

**Pairing and grants**

- **FR-009**: On first use the browser MUST make a P-256 key with WebCrypto, marked
  non-extractable, and keep it in IndexedDB for the page's origin. It MUST NOT keep any key,
  code or derived secret anywhere else: not in local storage, session storage, cookies, the URL
  or the page's logs.
- **FR-010**: The browser MUST pair with a client code, issued as `device` or `operator`, using
  058's code exchange, and be recorded as a client of kind `browser`, named after the browser
  and this Mac (for example "Safari on Alex's MacBook").
- **FR-011**: The browser MUST check that the control plane's key in the code is the one the
  control plane proves in its `ok`, and MUST refuse to pair otherwise.
- **FR-012**: The Mac window's **Settings ▸ Control plane ▸ Clients** MUST offer **Pair a
  Browser…**, and Agents Host's **Pair a Window or Phone…** MUST offer **A browser on this Mac**.
  Both show the code as text to copy, with the grant chosen first, defaulting to **Device**.
- **FR-013**: A browser MUST appear under **Clients** with its kind, grant and last seen, and be
  promoted, demoted and forgotten as any other client.
- **FR-014**: Forgetting a browser MUST close its socket on every copy within 2 seconds and
  refuse its next connection. The browser MUST then delete its key and show the pairing screen.
- **FR-015**: A client MUST be able to forget itself, whatever its grant, and only itself. The
  web remote's **Forget This Browser** uses it. The last operator still cannot be forgotten
  (058 FR-016).
- **FR-016**: The first version MUST use only methods the `device` grant allows. An operator
  grant MUST NOT make the first version offer anything more.

**The layout**

- **FR-017**: The page MUST show the Mac window's three columns: projects (under host headings),
  the chosen project's sessions with its workflows, and the chosen session's chat with the
  prompt at its foot.
- **FR-018**: Sessions MUST be grouped and ordered as in the Mac window, with the same status
  words, icons' meanings and labels. Only **Needs you** is drawn in colour.
- **FR-019**: The page MUST follow the widths in User Story 6 and the look gate's frames.
- **FR-020**: The page MUST follow the system's light or dark appearance, in the Mac window's
  Paper palette.
- **FR-021**: The page's title MUST show how many sessions need the person, so a background tab
  says so.
- **FR-022**: The browser MUST report presence as the Mac window does: active while the page is
  visible and focused, away otherwise, so notices go to the browser and not the phone while the
  person is working in it.

**Reading and answering**

- **FR-023**: The chat MUST show concise turns, tool calls, plans, turn detail (069) and
  background tasks (057), live, as in the Mac window.
- **FR-024**: Permission requests and question cards MUST be shown above the prompt and
  answerable; the first answer from any client wins.

**Sending and acting**

- **FR-025**: The prompt MUST send text with attachments, offer **Send now** on a queued prompt,
  and offer the mode, model and runtime menus the Mac window offers for that session.
- **FR-026**: The person MUST be able to start an agent in the project folder or in a new or
  existing worktree, with the runtime, model and mode chosen.
- **FR-027**: The person MUST be able to stop, park, unpark, archive and bring back a session,
  and add and remove its labels.
- **FR-028**: The person MUST be able to list a project's workflows and run one now.
- **FR-029**: The person MUST be able to open the session's files, the changes view and a live
  document, and type on a live document.

**Security**

- **FR-030**: Every page and file MUST be served with a Content Security Policy that allows
  scripts, styles, fonts and images only from the page's own origin (images also from `blob:`
  and `data:`), connections only to its own WebSocket, no inline script, no `eval`, no frames,
  no plugins, no forms posting anywhere and no embedding in another site. It MUST also send
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer` and a same-origin opener
  and resource policy.
- **FR-031**: Agent output, file contents and live documents MUST be rendered without raw HTML.
  Links MUST open in a new tab with no referrer and no opener. Remote images MUST NOT load. HTML
  files MUST show as source, and SVG only as a picture.
- **FR-032**: The web app MUST rely on no ambient credential. There are no cookies and no HTTP
  authentication, so a cross-site request has nothing to ride on, and the listener has nothing
  to change (FR-003).
- **FR-033**: Neither the control plane's logs nor the page's console MUST contain a code, a key,
  a MAC or the content of a message. The listener's access log MAY record a path and a status.
- **FR-034**: The web app MUST load nothing from any other origin: no CDN, no fonts, no
  analytics.

**Types that can't drift**

- **FR-035**: The web app's protocol types MUST be generated from the Swift source of
  `DaemonAPI` and the control types, and the build MUST fail when the checked-in types differ
  from a fresh generation.
- **FR-035a**: The web app's built static files MUST be checked in, and the build MUST fail when
  they differ from a fresh build of its source (D7).
- **FR-036**: Client-side rules the Mac window computes, such as session grouping, MUST be
  tested in the web app against the same fixtures the Swift tests use.

### What a stolen browser session could do

The browser's key is non-extractable: script cannot read it, only use it. What follows is what
each kind of theft gives, with a device grant, which is the default.

| Who has it | What they can do | What limits it |
|---|---|---|
| Script running in the page (a rendering bug, a malicious extension) | Anything the grant allows, while the page is open: read every conversation, start agents and answer their permission requests. **On a host, that is running commands.** | FR-030 and FR-031 keep agent output from running; extensions are the browser's to police. Forgetting the browser stops it at once. |
| Another process of this Mac's user account | No more than it already has: it can reach the host's own socket and files directly. | Nothing new is exposed by the browser. |
| A copy of the browser profile on another computer | Nothing in this version: the listener is loopback-only, so the key works only on this Mac. | Once #61 serves the web remote publicly, the key works from anywhere, and #42 must cover it. |
| A different user account on this Mac | It can reach the loopback listener, but has no key and needs a code. | Codes work once, for five minutes. |
| A website the person visits | Nothing: its WebSocket is refused on `Origin` (FR-005), DNS rebinding on `Host` (FR-004), and it has no key. | |

An operator grant adds the operator's powers (pairing clients, adding hosts, signing runtimes
in) to the first row, which is why codes default to **Device**.

### Key Entities

- **Web remote**: the static web app, served by the control plane on the loopback listener.
  It holds no state but the browser's key and what it last showed.
- **Browser client**: a client record of kind `browser`, with a name, a public key, a grant and
  when it was last seen. One per browser profile on this Mac.
- **Browser key**: a non-extractable P-256 key in the browser's IndexedDB for
  `http://localhost:<port>`. Losing it means pairing again.
- **Loopback listener**: the control plane's second listener, plain HTTP, on loopback only,
  with its own canonical origin.
- **Generated protocol types**: the TypeScript form of `DaemonAPI`'s and the control plane's
  messages, made from the Swift source and checked by the build.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A person with Agents Host running pairs a browser and sees their projects in under
  one minute from opening the page.
- **SC-002**: On a scratch walk with a real Claude turn, every first-cut action in #45 (answer a
  permission request and a question, send with an attachment, Send now, change model, start in a
  worktree, stop, park, archive, run a workflow, open a file, the changes view, a live page) is
  done from the browser, and the Mac window shows each one.
- **SC-003**: An update reaches the browser no more than half a second after the Mac window, at
  the median over a turn.
- **SC-004**: The page is usable within 2 seconds of opening, with 20 projects and 200 sessions.
- **SC-005**: For every seeded fixture, the browser and the Mac window put every session in the
  same group, in the same order.
- **SC-006**: A change to a protocol type in Swift that is not regenerated fails the build, every
  time.
- **SC-007**: Forgetting a browser cuts it off within 2 seconds, and its next connection is
  refused. Each refusal in the stolen-session table (FR-004, FR-005, FR-006, codes) is tested.
- **SC-008**: No page, file or WebSocket message reaches the browser from another origin, and no
  secret appears in a URL, a log or the console during a whole walk.
- **SC-009**: After the control plane has been stopped for a minute, the browser catches up
  within 5 seconds of its return, without a reload.

## Docs *(mandatory)*

- `docs/how-to/use-agents-in-a-browser.md` — add: open Agents Host, open the page, pair with a
  code, what works, forgetting a browser, and that other computers wait on #61.
- `docs/how-to/connect-a-window-or-phone.md` — change: add **Pair a Browser…** and **A browser
  on this Mac**.
- `docs/explanation/phone-and-ipad.md` — change: the browser is one more client, with what it
  can and can't do, and why it works only on this Mac for now.
- `docs/explanation/control-plane.md` — change: the loopback listener, the `browser` client
  kind, and the stolen-session table in brief.
- `README.md` — change: mention the web remote beside the iPhone and iPad.

## Out of scope

- Use from another computer: #61 (a public certificate) or a tunnel.
- A terminal (xterm.js over the host's pty).
- Settings, and anything else needing the operator grant: adding projects, browsing a host's
  folders, signing runtimes in, pairing, hosts.
- Notifications through Web Push, and installing as a PWA.
- Dictation.
- Sharing UI code with the Swift apps (D6).

## Assumptions

- **058 T106 lands first or alongside.** The web remote never touches the bridge or
  `DirectLink`; T106 removing them changes nothing here.
- **Browsers.** The current Safari, Chrome and Firefox on macOS. Each treats `http://localhost`
  as a secure context, offers WebCrypto ECDH, HKDF and HMAC there, and keeps a non-extractable
  `CryptoKey` in IndexedDB. The plan's first spike confirms this in all three before anything
  else is built.
- **The derived key.** ECDH's shared secret passes through the page's memory once per
  connection, on its way into a non-extractable HKDF key. Script running in the page could see
  it; that adds nothing to what the first row of the stolen-session table already gives.
- **Several tabs.** The control plane accepts several sockets of one client at once, or the tabs
  share one socket; the plan decides which.
- **Grants.** The device grant covers everything in the first cut, so no new method is added to
  it. The one new control-plane method is forgetting oneself (FR-015).
- **The look.** The web remote copies the Mac window's look and words, not a web style of its
  own, as in the look gate's frames A–F, approved by Alex on 2026-09-30.
- **The code text.** The existing client code format is used unchanged. The browser ignores its
  URL and pin, because it always dials the control plane that served the page.
