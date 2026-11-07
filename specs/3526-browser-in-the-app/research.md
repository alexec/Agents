# Spike #3527: the browser in the app

Part of epic #3526. Written 2026-11-05. This note settles the epic's open questions. It
has no product code. The stories that build it come from the "Stories" section, below.

## The decisions in short

| Question | Decision |
|---|---|
| WebKit or Chrome | **Chromium**, started by `agentsd` on the machine where the agent runs, with no window (`--headless=new`). Not WKWebView, and not the person's own Chrome. |
| How the agent drives it | **The Playwright MCP server** (`@playwright/mcp`), started by `agentsd` and pointed at that Chromium with `--cdp-endpoint`. The `agents` server offers its tools and filters what they send back. Two new tools on the `agents` server: `hand_to_person` and `fill_secret`. |
| How a client shows the page | **A stream of frames from Chromium** (CDP `Page.startScreencast`), sent by `agentsd` to the client the same way a terminal's output goes today. The client sends the person's clicks and keys back (CDP `Input.*`). The Mac and the web page use the same stream. |
| Per session or per machine | **One browser per machine** (per person), with **one profile that keeps sign-ins** between sessions. One agent drives it at a time, under the lease `browser:agents`. |
| How a secret fill stays out of page reads | `agentsd` types the value through CDP, never through the agent. It masks the field at its source, so screenshots and the stream show dots. It removes the value from every text the browser tools send back. The guarantee is the same as `ask_secret`'s. It is not a wall against an agent that tries hard (see "What the fill does not promise"). |

Decided: all of the above, because each is the option Claude (this agent) would mark
recommended and each is easy to undo before the first story merges. Alex can overrule.

## Why the browser runs on the machine, not in the Mac app

Principle 1 of `docs/explanation/direction.md`: nothing relies on the Mac, and the web page
is a full client. Agents run on Linux machines as often as on a Mac. An agent on a
DigitalOcean box cannot drive a WKWebView in a Mac window, and the web page has no Mac
at all. So the browser runs where the agent runs, beside `agentsd`, and every client looks
at it through `agentsd`. This is the shape that terminals already have (`shells.go`: a pty
on the machine, its output sent to each client, the person's keys sent back).

The Mac's own browser pane (`App/Sources/Sidebar/BrowserPane.swift`, a WKWebView for
the person, which the agent cannot drive) stays as it is. It is a different thing: the
person's view of a local server.

## WebKit or Chrome

| | WKWebView (WebKit) | Chromium on the machine | The person's own Chrome over CDP |
|---|---|---|---|
| Runs on a Linux machine | No (macOS and iOS only) | Yes | Only where the person is |
| Web client can show it | No | Yes (screencast) | Yes, but it is the person's whole browser |
| Agent can drive it | Only by our own tools over `evaluateJavaScript` | Playwright, over CDP | Playwright, over CDP |
| CAPTCHA | Supported by reCAPTCHA, hCaptcha and Turnstile | Supported | Supported, best signals |
| Extensions | No | Yes (`--load-extension` in Chromium builds) | Yes, the person's own |
| Size | 0 (in the OS) | About 570 MB (567 MB measured on a Mac, #3959), downloaded on first use | 0 |
| Licence | In the OS | BSD-3 (Chromium) | n/a |

- **WKWebView fails Principle 1.** It cannot run on a Linux machine, and it gives the web
  page nothing to show. It also has no automation protocol: we would write our own
  Playwright.
- **The person's own Chrome is out.** Chrome 136 and later ignore
  `--remote-debugging-port` on the default profile, on purpose, to stop the theft of
  cookies. To get round it we would need the person to run a second Chrome, which is
  the same as ours but harder to set up. It is also only where the person is, not where
  the agent is. The "Use Chrome" option (#1837, Claude in Chrome) stays for a person who
  wants an agent in their real Chrome.
- **Which Chromium:** the build that Playwright installs (`playwright install chromium`).
  It has builds for macOS (arm64, x64) and Linux (x64, arm64). Chrome for Testing has no
  Linux arm64 build, and branded Chrome 137 and later dropped `--load-extension`.
  `agentsd` downloads it on first use into `~/.agents/browser/`, not in the app bundle,
  so a person who never uses the browser pays nothing.

### CAPTCHA pass rates

Not measured in this spike: a fair measure needs many runs against live sites from many
addresses, which is more than three days and is load on other people's services. What
we know:

- reCAPTCHA, hCaptcha and Cloudflare Turnstile all support Chromium and WebKit. The
  engine is not what fails a check. The signals are: `navigator.webdriver`, a headless
  user agent, a data-centre IP address, a new profile with no history.
- **We do not try to beat bot detection.** That is detection evasion. A CAPTCHA is the
  reason for the hand-off: the person solves it, in the stream, with real input events
  (CDP `Input.dispatchMouseEvent` makes trusted events). A kept profile (below) means a
  site sees the same browser again, which is what lowers the number of challenges
  honestly.
- A site that refuses a headless browser outright is possible. The fix is a browser with
  a window on a virtual display (Xvfb on Linux, an off-screen window on the Mac). That is
  a follow-up story, filed only when a real site needs it.

### Licence and size (AGENTS.md, "Libraries before our own code")

| Library | Purpose | Licence | Latest | Size |
|---|---|---|---|---|
| Chromium (Playwright's build) | The browser | BSD-3 | follows Playwright | About 570 MB (567 MB measured on a Mac, #3959), downloaded on first use |
| `@playwright/mcp` | The agent's browser tools | Apache-2.0 | v0.0.84, 2026-10-31; 39k stars | npm package plus Playwright |
| `github.com/chromedp/cdproto` (and `chromedp`) | `agentsd` speaks CDP: screencast, input, fill, mask | MIT | v0.22.1, 2026-11-04 | Go, no cgo |
| `github.com/modelcontextprotocol/go-sdk` | `agentsd` is the Playwright server's MCP client | MIT | already in `go.mod` (v1.8.0) | already in |

`@playwright/mcp` needs Node 18 or later on the machine. The first story says how
`agentsd` gets it (a machine that runs Codex or OpenCode has it already; a machine that
does not gets it with the browser download).

## How the agent drives it

`agentsd` starts the Playwright MCP server as its own child for each session that asks
for the browser, with `--cdp-endpoint` set to the machine's Chromium. The `agents`
server offers the Playwright tools to the agent (`browser_navigate`, `browser_snapshot`,
`browser_click`, and the rest) under the same names, and passes each call through.

- **Why not our own tools:** Playwright's tools are good, used by many, and kept up to
  date by Microsoft. An accessibility snapshot with references is the best way for a
  model to read a page. Writing our own is weeks, and worse.
- **Why not give the agent the Playwright server directly:** three things need
  `agentsd` in the path:
  1. **The filter.** Each result goes through `agentsd`, which removes secret values
     and masks images (below).
  2. **The hand-off.** While the person has the page, `agentsd` holds the agent's browser
     calls and answers them with "the person has the page" until the person taps Done.
  3. **The lease.** The first browser call takes `browser:agents` (the existing lease
     system, `leases.go`), so two agents on one machine do not click on the same tab.
- **A runtime's own browser stays.** An agent can still add Playwright from the
  marketplace, and Claude can still use "Use Chrome". Those browsers have no hand-off
  and no fill. The app's tool descriptions say to use the app's browser for a page a
  person may need to see.

### The two new tools on the `agents` server

- **`hand_to_person(reason, step)`.** It puts a question card in the chat: the reason,
  the step ("Solve the CAPTCHA", "Sign in to GitLab") and **Open the page**. The card
  opens the browser view at the agent's tab. The person does the step in the stream and
  taps **Done** (or **Can't do it**, with a line of text). The tool returns that answer.
  It is an ordinary question: it notifies, it shows on every client, and a workflow can
  wait on it.
- **`fill_secret(secret, field)`.** It names a secret from Settings ▸ Secrets and a field,
  by CSS selector or by its label. `agentsd` reads the value from the machine's
  `secrets.env`, finds the field through CDP (also in a cross-origin frame, such as a
  Stripe card field, through `Target.setAutoAttach`), focuses it and types the value with
  `Input.insertText`. It returns "filled", never the value. A card secret has parts
  (number, expiry, CVC, name, postcode); `fill_secret` with a card fills each part by
  the field's `autocomplete` attribute (`cc-number`, `cc-exp`, `cc-csc`, `cc-name`,
  `postal-code`), the standard that card forms use.

## How a client shows the page

- `agentsd` calls `Page.startScreencast` (JPEG, quality about 60, at the size of the
  client's view) only while a client watches, and stops it when none does. Each frame
  goes to the client as an event, as a terminal's output does. The client's ack is the
  CDP `Page.screencastFrameAck`, so a slow client gets fewer frames, not a backlog.
- The client sends the person's input back as a request: a click, a scroll, a key, a
  piece of text (for pasting), and the view's size. `agentsd` turns each into CDP
  `Input.dispatchMouseEvent`, `Input.dispatchKeyEvent` or `Input.insertText`.
- A small bar over the stream has Back, Forward, Reload, the address, and Done when a
  hand-off is open.
- **Mac:** the stream in the side pane, beside the chat, as a new pane next to Files,
  Browser and Terminal. **Web:** the same view, in the same place. **Remote:** the same
  stream in its Browser pane (Core since #3800; it was `remote: tier mac+web`). The
  hand-off card is a question card (Core): on the Remote, Open the page opens that pane.
- **Through the control plane:** frames for a hosted folder go through the control plane
  like every other message. It routes them and keeps none (Principles 6 and 7), and TLS
  protects them in transit (Principle 8).

Why not a video stream (WebRTC, H.264) or VNC: a hand-off is a few clicks on a page that
changes little. A screencast is a few frames a second when the page changes and none
when it does not. It needs no media server and goes through the control plane's existing
message path. Video is a later story if people find the stream slow.

## Per session or per machine

- **One Chromium per machine, per person**, started on first use and stopped after an
  idle time. Its profile is `~/.agents/browser/profile/` on that machine.
- **Sign-ins are kept** between sessions. A person signs in once (by a hand-off), and
  agents on that machine use the sign-in after. This is the point of the feature:
  "agents should not ask a person for help when a guardrail can do it". Settings ▸
  Browser (a later story) shows the sites with sign-ins and clears them.
- **One agent at a time**, under the lease `browser:agents`. The others wait in line, as
  for a simulator. Each agent's tabs are its own; the next agent starts with a new tab and
  the same cookies.
- **Per session profiles** (empty cookies each time) were the other option. They make
  every sign-in a hand-off, every time, which is what the epic wants to stop. A session
  that must be apart can get a private context (Playwright's `--isolated`) as a later
  option.
- **Risk:** any agent on that machine can act on a site the person signed in to there.
  That is the same trust as today's `secrets.env`, which every agent on the machine can
  use. The sign-ins are in the app's own profile, not the person's real Chrome, so only
  what the person signed in to for agents is there.

## How a secret fill stays out of the agent's page reads

The value goes from `secrets.env` to the page through `agentsd` and CDP. It never goes
through the agent, the model, the transcript or the logs. After that, it is in the page,
so each way the agent reads the page is closed:

1. **Pixels: masked at the source.** After the fill, `agentsd` sets
   `-webkit-text-security: disc` on the field (and in its frame). Screenshots, the
   accessibility snapshot's picture and the stream to the person all show dots. So the
   number is not in the frames that go through the control plane either, which keeps the
   PCI DSS decision in #3526 true. `agentsd` puts the style back if the page draws the
   field again (a DOM mutation watch on the filled node).
2. **Text: removed by `agentsd`.** Every text result of a browser tool (snapshot,
   console, network, evaluate) goes through a filter that replaces each value filled in
   that browser, and its usual forms (with or without spaces and dashes, the last four
   digits kept for a card), with `<secret NAME>`. Playwright's own `--secrets` option does
   the same and is on as well, but its documentation says it is "a convenience and not a
   security feature", so the filter in `agentsd` is the one we rely on.
3. **Images: masked by `agentsd`.** A screenshot result also goes through `agentsd`,
   which paints over the boxes of the filled fields (`DOM.getBoxModel`) before the agent
   gets it, in case the style failed.
4. **Values out of the page:** `browser_evaluate` and `browser_run_code` on a page with
   a filled field are refused until the page navigates. A script can read
   `input.value` in many ways that a string filter can miss (for example, one digit at a
   time).

### What the fill does not promise

The agent runs as the person, in the same Unix account as `agentsd` and Chromium. An
agent that tries hard can read `secrets.env` itself, or find Chromium's debugging port and
talk to it. That is true of every secret today (`ask_secret`, #2885). So the promise is
the same as `ask_secret`'s: the value is never in what the app sends to the agent or the
model, or in the transcript, the logs or a screenshot. For a hard wall, use the sandbox
(`sandbox: required`, `docs/reference/policy.md`): a sandboxed agent cannot read the home
folder or open the port. The Chromium port listens on `127.0.0.1` only, on a random
port, with a random path token.

This is why the epic's guardrail matters more than the mask: a card for agents is
locked to one merchant and has a spend limit, so a leak costs at most that limit.

### A secret the person types in a hand-off

When the person signs in during a hand-off, they type a password into the stream. It is
in the page like a filled value. `agentsd` treats every `type=password` field and every
field with `autocomplete` `cc-*` or `one-time-code` that the person typed into during a
hand-off the same way as a filled field: masked and filtered. A value it cannot know
(the person types it) it filters by the field's DOM value, read by `agentsd` at Done.

## Stories

The lead files these as sub-issues of #3526. Each is one lane.

1. **Task: the machine's browser.** `agentsd` downloads Playwright's Chromium on first
   use, starts it headless with the kept profile on `127.0.0.1`, stops it when idle, and
   offers the lease `browser:agents`. Go only; `chromedp`. Includes how Node gets to the
   machine.
2. **Task: the browser tools.** The `agents` server runs `@playwright/mcp` per session
   over `--cdp-endpoint`, offers its tools, takes the lease on the first call, and filters
   the results (text and images). Blocked by 1.
3. **Story: watch the page (Mac and web).** The wire's screencast event and input
   request (`Packages/Wire` first), the view on the Mac and the web page. `remote: tier
   mac+web`. Blocked by 1. Needs Alex's approval (a new pane).
4. **Story: hand it to the person.** `hand_to_person`, the card on all three clients
   (Core), the hold on the agent's calls, Done and Can't do it. Blocked by 2 and 3.
5. **Story: fill a secret.** `fill_secret`, the mask, the filter, the evaluate refusal,
   and card parts by `autocomplete`. Blocked by 2.
6. **Story: card secrets with guardrails.** Settings ▸ Secrets marks a card secret and
   says it is for agents only when it is locked to a merchant and has a spend limit. Mac
   and web. Blocked by 5.
7. **Story: Settings ▸ Browser.** The sites with sign-ins, Clear, and the download's size.
   Mac and web. Blocked by 1.

Later, filed only when needed: a window on a virtual display for a site that refuses
headless; a private context per session; video instead of frames.

## Sources

- `@playwright/mcp`, its options and `secrets` note: https://github.com/microsoft/playwright-mcp
  (`config.d.ts`).
- Chrome 136 and remote debugging on the default profile:
  https://developer.chrome.com/blog/remote-debugging-port
- CDP `Page.startScreencast`, `Input.*`, `Target.setAutoAttach`:
  https://chromedevtools.github.io/devtools-protocol/
- `chromedp`: https://github.com/chromedp/chromedp
- Existing code: `Go/internal/agentsd/shells.go` (a stream to every client),
  `secretask.go` (`ask_secret`), `leases.go` (`browser:` leases), `chromeoption.go`
  ("Use Chrome", #1837), `App/Sources/Sidebar/BrowserPane.swift` and
  `Packages/AgentsKit/Sources/AgentsKitCore/Files/BrowserPolicy.swift` (the person's pane).
