# Videos for 1.0: the catalogue, and a dress rehearsal (#4832)

Status: draft (Product Owner, 2026-11-11; section 1 written again for #5074, 2026-11-12). Epic #4832, milestone `1.0 Public release`.

Alex, 2026-11-11: two jobs. (1) Find which videos are needed. (2) Do a dress rehearsal:
write the script of one video (what is shown and what is said), record it, and get it onto
YouTube.

## What we have already

- `scripts/video/` (#1078, #1793) makes a narrated video with no person: a scratch app,
  recorded through its walk socket (no other window can be in the picture), the Chatterbox
  voice (Alex, 2026-10-15), Whisper checks, captions (WebVTT), a contact sheet.
- Seven scenes: A2, U1, U3, U4, U5, U8, U9, and `i-linear`. Their videos were made on
  2026-10-16 and never uploaded. Since then the UI changed: one app (#4225), "project" →
  "folder" (#2617), the Get started card, Auto, voice mode, the Brief.
- `upload.py` uploads **only integration videos**, private, to the playlist `Agents
  integrations`. The YouTube sign-in was never done: the token file is still a copy of the
  client file, and the OAuth app may still be in Testing (#1856).

## 0. Why: three uses of one tool (Alex, 2026-11-11)

Alex's other motive: the same recording tool also gives (a) **videos of changes on a PR**,
and (b) **videos of how to set up an integration**, to help people understand them. The
rehearsal proves the tool for all three. Options, the recommended one first (not decided):

**(a) PR clips.**

1. *Recommended:* a silent **animated WebP** (no sound, about 10–20 s, under 5 MB) made from
   the walk's frames by the same recorder (`make.py` through the walk socket), put on the
   orphan `screenshots` branch by `pr-shots.sh`. It plays inline in the PR body. This is
   #4094. It needs no account and no quota, and a scratch app has nothing of Alex's in it.
2. A narrated MP4 on the Loops channel, **unlisted**, linked from the PR. GitHub shows only
   a link (no player), each upload publishes to an outside site, and the YouTube Data API's
   daily quota allows only a few uploads a day by default (an upload costs most of it). Good
   for a large stack's one review video, not for every PR.
3. An MP4 file on the `screenshots` branch: GitHub shows it only as a link to download.

**(a′) Sound (Alex, 2026-11-11: "I want to test sound").** A WebP clip has no sound, and the
tool records pictures only. The app's sounds are voice mode's speech and sounds. Spike #4844
finds out if a scratch app plays them, how to get them into the take (recommended: a
walk-only tap of what the app plays, mixed under the frames), and if an agent can put an MP4
with sound inline on a PR (an upload in the github.com comment box). Until then: a silent
clip for motion, and a video with sound only where sound is the change.

**(b) Integration set-up videos for people.**

1. *Recommended:* one scene, two cuts. The `i-<name>` scene (#1793) already shows the
   set-up on a real account. Add a **help** cut: plain narration for someone new (what the
   integration is for, where to click, what they see after), no internal words (PKCE, events
   server), public on the Loops channel, on the docs page `docs/how-to/use-<name>.md`. The
   private check cut for Alex stays.
2. A separate scene per integration for help only: more work, and two scenes to keep true.

A public cut needs a **demo workspace** on each provider (a Linear workspace named for the
demo, not Alex's), because the workspace name and the members show in the frames. That is
`needs-account` per provider. Tokens keep the three defences of #1793.

Where these go in the epic: (a) is #4094, which can run now; (b) is the **Public** column of the
integration videos (1.3).

## 1. The catalogue

Written again for #5074 (2026-11-12), for Alex to read and approve as text before more
takes. Alex, 2026-11-12: "Videos seem expensive to make, esp review and rework. I want to be
careful with them." … "We should probably have one video for every feature. And then one
for every integration."

The rules of #1078 stay: the story leads with what only Agents does (agents that work
together and on their own), every claim is checked against
`docs/reference/feature-matrix.md` before it is said, scratch data only, the person on camera
is "Sam", and the voice is a directed script (2.4, #4964).

There are three groups now, not three kinds of each:

- **Feature videos (F):** one for each feature a person can see. One cut: two or three lines
  of story (why), then the task (how), with the exact names on the screen. On the feature's
  docs page and on www's feature section. Made again when the feature's UI changes.
- **Integration videos (I):** one for each integration a person uses, on a real account
  (#1793): the set-up and one use. The private check for Alex is the take; the **public**
  cut is the same take, when a demo account shows nothing of Alex's (0(b)).
- **Marketing (M):** only a story that spans features. One is kept: M1.

Decided: a feature video is one cut that is both the story and the task, not a marketing
cut and a usage cut, because two cuts of each feature double the takes, reviews and
reworks that Alex wants to keep small. Alex can overrule.

### 1.1 Sizes, from U1's retro (2.4)

Each size is what one video costs: the take (a lane's time, to the private upload), Alex's
review (read the script, watch the upload, answer the form) and one rework (a change of the
script or the scene, a new take and upload).

| Size | When | Take | Alex's review | One rework |
|---|---|---|---|---|
| **S** | The scene exists (stale) or is scratch data only, with no new tool | about 1 h (U1's take: 1 h; the upload is one step now) | about 10 min | about 1 h |
| **M** | A new scene, or a seeded state, a faked limit or a time cut | 2–3 h | about 10 min | 1–2 h (U1's voice rework: 2 h) |
| **L** | A real account (a demo workspace; a token made, blurred, checked and revoked), a native phone recording, or the installed app | half a day, plus the account (`needs-account`) | about 15 min | about 2 h |

The money is small for every size: a few cents of a runtime's turn per take, on the
subscription, and no money for YouTube (an upload with captions is about 2,000 of the
10,000 daily quota units). The cost is time: the lane's, and Alex's.

### 1.2 Feature videos

The features are the `feature:` labels, with the feature matrix's features that have no
label put under the label nearest to them. The old rows' ids are in brackets: a marketing
video about one feature (M2–M7) is now that feature's video.

| # | Feature | Story (one line) | Length | Docs page | Needs | Size | For 1.0 |
|---|---|---|---|---|---|---|---|
| F1 | **Your first agent** (the core: sidebar, sessions, chat) [U1] | Add a folder, start an agent, say Yes once, read its reply and its change. | 45 s | Tutorials ▸ First agent | — | done | **done**: a public video, private on YouTube until open question 2; made again after #5057 (the Get started card goes) |
| F2 | **Needs you** [M2, U3] | Four agents work; one asks; the card on the phone, one tap, the Mac carries on. | 40 s | How-to ▸ Answer a question | the web page at phone size (native phone later) | S | yes |
| F3 | **Live documents** [M6, U5] | Watch the work, not the chat: a document fills in beside the chat, a diagram arrives. | 30 s | How-to ▸ Follow a live document | — | S | yes |
| F4 | **Review the work** [U4] | The Changes pane coloured to the word, then the pull request and its checks. | 30 s | How-to ▸ Read an agent's changes | — | S | yes |
| F5 | **Several agents, a worktree each** [U8] | Three agents on one folder, each on its own branch, none in another's way. | 25 s | How-to ▸ Start in a worktree | — | S | yes |
| F6 | **The web page** [U9] | The same sessions in a browser, on any computer. | 25 s | How-to ▸ Use Agents in a browser | — | S | later |
| F7 | **Send while it works** [U7] | Steer an agent mid-turn; the message waits for its turn or goes now. | 25 s | How-to ▸ Send while an agent works | — | M | later |
| F8 | **Runtimes** [M3, U11, U14, U15] | The agents you already have: Claude, Codex and Copilot side by side; Auto picks; one runs out and the session carries on. | 40 s | How-to ▸ Use Auto | two or three signed-in runtimes; a faked limit | M | yes |
| F9 | **Workflows, waits and leases** [U6] (`events`, `capacity`) | An agent ends its turn, spends nothing, and wakes on an event; two agents take turns with one simulator. | 45 s | How-to ▸ Set up a workflow | time cut | M | yes |
| F10 | **It keeps working without you** [M5] (`daily-summary`) | Close the window, the agents carry on; the Mac restarts, they pick up; the Brief says what happened. | 30 s | How-to ▸ Watch background work | scripted host restart | M | later |
| F11 | **The Remote** [U2] (`remote`) | Follow and answer your agents from iPhone, the lock screen and a Live Activity. | 60 s | Tutorials ▸ Follow from iPhone | native phone recording (XCUITest, #1078 item 2) | L | later |
| F12 | **Voice** [M4] | Say what you want, hear the reply, answer a question by voice. | 30 s | — (an issue, with the take) | the installed Mac app (open question 3) | L | later |
| F13 | **The Work view** (`work`, `planning`) | Issues and pull requests in one list; start an agent from an issue; an epic's plan and what it costs. | 40 s | Explanation ▸ Planning | a demo repository (the GitHub video's) | M | later |
| F14 | **What an agent drives** (`browser`, `live-tiles`, the simulator pane) [U16] | The agent drives a browser and the simulator in a tile; you take it over in its own window. | 30 s | How-to ▸ Use the simulator pane | the walk simulator | M | later |
| F15 | **Your setup** (`your-setup`) [U10] | Add a connector from the registry, sign it in, and every machine has it. | 30 s | How-to ▸ Add a connector from the registry | a server with no sign-in | M | later |
| F16 | **Cost and limits** [M7, U12] (`multiplier`) | Spend across runtimes and machines as one figure, a daily limit, and the Multiplier. | 25 s | How-to ▸ See usage, cost and time | seeded usage; a faked limit | M | later |
| F17 | **Machines** [U13] (`machines`) | Add a machine; send a folder to it; its agents show beside this Mac's. | 45 s | How-to ▸ Add a machine | the devbox (waits on #5018: no Docker on this Mac) | L | later |
| F18 | **Agents with no Mac** (`no-mac`) | A control plane in the cloud, cloud machines, and the web page: no Mac at all. | 40 s | How-to ▸ Run agents with no Mac | a scratch control plane on a cloud machine | L | later |
| F19 | **Channels** (`channels`) | Reach your agents from Slack: a question in a thread, the answer in the thread. | 30 s | How-to ▸ Reach agents from Slack | a demo Slack workspace (the Slack video's) | L | later |
| F20 | **Find a session** (`session-search`, labels, pins, archive) | Label sessions by issue; find one by its label; pin and archive. | 25 s | How-to ▸ Label a session | seeded sessions | M | later |
| F21 | **Docs** (`docs`) | A folder's docs beside Work; pin a page; an agent reads them. | 25 s | How-to ▸ Pin a page to a folder | — | M | later |
| F22 | **Projects** (`projects`) | Many folders on many machines join one project. | 30 s | Explanation ▸ Folders, machines and worktrees | two scratch machines | M | later |
| F23 | **People and policy** (`policy`, teams) | Invite someone; set what agents may do for the organisation and for one folder. | 40 s | How-to ▸ Set an organisation policy | two scratch people | M | later |
| F24 | **The hosted service** (`hosted`) | Sign up on agentloops.dev and have a control plane of your own. | 45 s | Tutorials ▸ Sign up for the hosted service | the live hosted service, a demo account, Stripe's test mode | L | later |
| F25 | **Delivery** (`delivery`) | From a merged pull request to production: the deploy waits for you, then the health of what shipped. | 40 s | How-to ▸ Deploy to Cloud Run | a demo Google Cloud project (the Cloud Run video's) | L | later |
| F26 | **Let's build your idea** (`first-build`) | First open: say what to build; an agent plans it and builds a first app. | 45 s | — (#5055 writes it) | waits for #5053–#5057 | M | later |

**Left out, and why:**

- **Not seen by a person:** `performance`, `data`, `design`, `autonomy`, and
  `public-release` (a milestone, not a feature).
- **One video for each part instead:** `integrations` and `git-hosts` are themes made of
  integrations, so each one has an I row. `agent-identity` (the agents' bot) shows in the
  GitHub video, where its pull requests are.
- **Shown inside another video:** `sidebar` and `one-mac-app` (the download) in F1;
  `web-links` (a link to the web page) in the feature that it opens.
- **Not built yet:** `screens` (Linux, Windows and Android clients, #4494–#4496). It gets a
  row when it ships.

### 1.3 Integration videos

One row for each integration of `docs/reference/integrations.md` that a person uses. Rows
that a person does not set up or see are left out (below). Several rows of the reference
page that are one service to a person (GitHub's sign-in, server, bot, Codespaces and Work
pages) are one video. **Public** says if a public cut can be made, and what it needs; until
then each one is a private check for Alex (#1793).

| # | Integration | Story (one line) | Length | Docs page | Needs | Public | Size | For 1.0 |
|---|---|---|---|---|---|---|---|---|
| I1 | **GitHub** (sign-in, the github server, the agents' bot, pull requests, checks, the cost comment) | Agents do GitHub work: an issue starts an agent, it opens a pull request as its bot, the checks pass, you approve and it merges (#5075 script, #5076 take). | 60 s | How-to ▸ Use GitHub | a demo repository and the agents' bot; a time cut | yes, the agents' own account | L | **yes, first** |
| I2 | **Linear** | Connect Linear; an issue starts an agent; its state follows the work. | 40 s | How-to ▸ Use Linear issues | the demo workspace; `i-linear` exists (stale) | yes, with a demo workspace | M | yes |
| I3 | **GitLab** | Connect GitLab; a merge request and its pipeline from an agent. | 40 s | How-to ▸ Use GitLab | a demo group on gitlab.com (agentstest) | yes, with a demo group | L | later |
| I4 | **Jira** | Jira issues on the Work page; start an agent from one. | 40 s | How-to ▸ Use Jira issues | a demo Jira site | yes, with a demo site | L | later |
| I5 | **Forgejo** (and Codeberg) | Connect Forgejo; pull requests and issues on the Work pages. | 40 s | How-to ▸ Use Forgejo | a demo repository on Codeberg | yes | L | later |
| I6 | **Bitbucket** | Connect Bitbucket with an API token; pull requests and Pipelines. | 40 s | How-to ▸ Use Bitbucket | a demo workspace | yes, with a demo workspace | L | later |
| I7 | **Azure DevOps** and **Azure Boards** | Connect Azure DevOps; pull requests, Pipelines and work items. | 45 s | How-to ▸ Use Azure DevOps | a demo organisation | yes, with a demo organisation | L | later |
| I8 | **CodeRabbit** | A second agent reviews: CodeRabbit's review wakes the agent, which answers it. | 30 s | How-to ▸ Use GitHub | the GitHub video's repository, with CodeRabbit on it | yes | M | later |
| I9 | **Email** | An agent waits for a mail (a sign-in code) and goes on when it comes. | 30 s | How-to ▸ Wait for mail | the agents' own mailbox (agentloops@fastmail.com) | yes, the agents' own account | M | later |
| I10 | **Slack** | A Slack app for your agents: a question in a thread, the answer there. | 40 s | How-to ▸ Reach agents from Slack | a demo Slack workspace | yes, with a demo workspace | L | later |
| I11 | **Google Chat** | The same in Google Chat. | 40 s | How-to ▸ Use Google Chat | a demo Google Workspace | yes, with a demo workspace | L | later |
| I12 | **WhatsApp** | The same on a WhatsApp Business number. | 40 s | How-to ▸ Use WhatsApp | a test number on Meta's Cloud API | private (a phone number shows) | L | later |
| I13 | **Sentry** | A new Sentry issue starts an agent that fixes it. | 30 s | How-to ▸ Use Sentry | a demo Sentry organisation | yes, with a demo organisation | L | later |
| I14 | **Better Stack** | A monitor goes down; an agent finds why. | 30 s | How-to ▸ Use Better Stack | a demo Better Stack team | yes, with a demo team | L | later |
| I15 | **Google Cloud Run** | A merge deploys to Cloud Run through the customer's own GitHub Actions. | 40 s | How-to ▸ Deploy to Cloud Run | a demo Google Cloud project | yes, with a demo project | L | later |
| I16 | **Claude** (runtime, and several accounts) | Sign Claude in; a turn; the plan window's allowance. | 25 s | How-to ▸ Sign a runtime in | a signed-in account | private (the account shows) | M | later |
| I17 | **Codex** (runtime, and several accounts) | The same for Codex. | 25 s | How-to ▸ Sign a runtime in | a signed-in account | private | M | later |
| I18 | **Copilot** | The same for Copilot. | 25 s | How-to ▸ Sign a runtime in | a signed-in account | private | M | later |
| I19 | **Grok** | The same for Grok, and its billing. | 25 s | How-to ▸ Sign a runtime in | a signed-in account | private | M | later |
| I20 | **Antigravity** | The same for Antigravity. | 25 s | How-to ▸ Sign a runtime in | a signed-in account | private | M | later |
| I21 | **OpenCode** | OpenCode with the Mac's provider keys. | 25 s | How-to ▸ Sign a runtime in | a provider key | private | M | later |
| I22 | **Cursor** | The same for Cursor. | 25 s | How-to ▸ Sign a runtime in | its row is `broken` (fails at turn): after the fix | private | M | later |
| I23 | **Org keys and gateways** (Anthropic, OpenAI and xAI keys; Bedrock, Vertex AI, Azure, a base URL) | An organisation's key or gateway, on every machine. | 40 s | How-to ▸ Add an org key or gateway | one gateway account (Bedrock or Vertex) | private (a key's account shows) | L | later |
| I24 | **GitHub Codespaces** | A codespace as a machine for agents. | 40 s | How-to ▸ Set up a cloud machine provider | the GitHub video's repository | yes | L | later |
| I25 | **Coder** | A Coder workspace as a machine. | 40 s | How-to ▸ Set up a cloud machine provider | a Coder deployment | yes, with a demo deployment | L | later |
| I26 | **Google Compute Engine** | A Compute Engine VM as a machine, started and stopped by agents. | 40 s | How-to ▸ Start machines from agents | a demo Google Cloud project (I15's) | yes | L | later |
| I27 | **AWS EC2** | The same on EC2. | 40 s | How-to ▸ Set up a cloud machine provider | an AWS account | yes, with a demo account | L | later |
| I28 | **DigitalOcean** | The same on DigitalOcean. | 40 s | How-to ▸ Set up a cloud machine provider | a DigitalOcean account | yes, with a demo account | L | later |
| I29 | **Docker** | A container on this Mac as a machine. | 30 s | How-to ▸ Add a machine provider | Docker (none on this Mac now, #5018) | yes | M | later |
| I30 | **Google Cloud Workstations** | The same on Cloud Workstations. | 40 s | How-to ▸ Set up a cloud machine provider | its row is `broken` (Start): after the fix | yes | L | later |
| I31 | **Catalogues** (the MCP registries, skills.sh, GitHub skill and plugin sources, a custom marketplace) | Add a connector and a skill from a catalogue. | 30 s | How-to ▸ Add a skill from a catalogue | — | yes | M | later |
| I32 | **Sign in with Google, Apple or GitHub** | Sign in to a control plane with an account you have. | 30 s | How-to ▸ Sign in with Google, Apple or GitHub | the agents' own accounts | yes, the agents' own accounts | M | later |
| I33 | **Your organisation's sign-in** (Okta, Entra ID, Google Workspace, any OIDC; SCIM) | People sign in with the organisation's account; SCIM adds and removes them. | 45 s | How-to ▸ Sign in with your organisation | the Okta developer org (walked); Entra and Workspace orgs | yes, with demo orgs | L | later |

**Left out, and why:** what a person does not set up or see, or sets up only as part of a
row above.

- **Part of another video:** the runtime downloads (Node, npm, the install scripts) and the
  allowance rows (plan windows, limits from error text, Codex token refresh) happen inside
  a runtime's video or F8; MCP OAuth is inside each connector's sign-in; GitHub's Work
  pages, plans and deploy waits are in I1 and F13; Stripe is in F24; "any MCP or CLI
  provider" is in F17.
- **Not seen by a person:** events from MCP servers by polling, git credentials lent to a
  Linux host, Bonjour, ssh tunnels, notifications (APNs, Web Push, Live Activities, local
  notifications: seen in F2 and F11, with no set-up of their own), the misbehaving fake
  provider.
- **For an operator, with no screen to show:** the control plane's hosting (S3 or MinIO,
  KMS, Caddy, Google Cloud, Cloudflare DNS), the audit sinks, OTLP metrics and the read
  API. *Run the control plane in the cloud* is a how-to page, not a video. A row can be
  added if people ask.
- **Ours, not the product's:** the docs site and www (GitHub Pages, Cloudflare Pages).
- **Removed or retired:** Gemini, Goose, the Channels layer, the CloudKit relay and mailbox.

### 1.4 The order, and a short set for 1.0

**The GitHub video goes first** (Alex's choice): I1, its script (#5075) and then its take
(#5076).

**One at a time.** Each video's script goes to Alex as text first (as #5075 does), and the
next take starts only after Alex's watch of the one before it. A lesson from one rework then
is in every later script, not found again in each.

**The short set for 1.0**, eight videos after F1 (done), in this order:

| Order | Video | Size | Why here |
|---|---|---|---|
| 1 | I1 GitHub | L | Alex's choice; most people's forge; it shows agents that work together and on their own |
| 2 | F2 Needs you | S | the scene exists; what a person does every day (core usability, #2800) |
| 3 | F4 Review the work | S | the scene exists; follows I1's pull request |
| 4 | F3 Live documents | S | the scene exists; only Agents does it this way |
| 5 | F5 Several agents, a worktree each | S | the scene exists |
| 6 | F9 Workflows, waits and leases | M | what only Agents does; M1 reuses its scene |
| 7 | F8 Runtimes | M | the agents people already have |
| 8 | M1 One afternoon | M | the hero, for www; made last of the set, from the scenes above |
| 9 | I2 Linear | M | the pilot scene exists; the most used tracker after GitHub |

**Its cost**, from 1.1: one L, four S, four M. Takes: about half a day + 4 h + 10 h, so
about 2½ lane-days. Alex: about 1 h 35 min to review them all, plus about 10 min for each
rework. With one rework each (U1 had two), add about 12 h of lanes.

**After 1.0**, in this order: the rest of the S and M feature videos (F6, F7, F10, F13,
F14, F15, F16, F20, F21), then the L ones as their accounts and tools are ready (F11, F17,
F18, F19, F12, F23–F26), and the integration videos in the order of their public cut (I3–I15,
then I24–I33), with the runtimes' private checks (I16–I23) made again when the runtime check
finds a change.

**M1 One afternoon** stays a marketing video because its story spans features: a workflow
(F9) starts a tester, a lease (F9) holds it in line, it waits for `main` (I1), and a release
agent wakes. Length 60 s, on www and *Why Agents*.

## 2. The dress rehearsal: U1 "Your first agent"

The rehearsal makes one video through every step that every later video takes, and writes
down what broke. It is not the final U1: it may be made again.

### 2.1 The script: what is shown and what is said

Layout `mac`. Scratch app on `/tmp/run-vid-u1`, person "Sam", folder `weather` (the
tutorial's Fahrenheit bug), runtime Claude. About 60 s after the cuts. Each line starts at
its marker; `fast` spans are cut to the time given. The words below are what is said; the
directions (pauses, pace, tone) are in `scripts/video/scenes/u1.py` (#4964).

| # | Marker | What is shown | What is said | Time |
|---|---|---|---|---|
| 1 | `intro` | The Agents window, empty, the **Get started** card at the top of the sidebar, the first step ticked. | "This is Agents. Here's how to start your first agent." | 4 s |
| 2 | `folder` | **Add a folder** on the card; the folder `weather` is chosen; it appears in the sidebar and the card ticks the step. | "A folder is a directory you work in. Add one, and it appears in the sidebar." | 6 s |
| 3 | `new` | **New Session** on the folder; the start form, the runtime **Claude**. | "Click New Session. The agent works in this folder, with Claude as its runtime." | 6 s |
| 4 | `prompt` | The prompt is typed: *Fix the Celsius conversion and run the tests.* | "Say what you want done. Here: fix the Celsius conversion, and run the tests." | 6 s |
| 5 | `send` | Send; the session appears as **Working** in the sidebar. | "Send it, and the agent starts at once." | 4 s |
| 6 | `ask` | A permission card: the agent wants to edit `Forecast.swift`. **Yes** is clicked. The session's row says it needs you, then working again. | "Before it changes a file or runs a command, it asks. Click Yes." | 7 s |
| 7 | `steps` | `fast(4)`: its steps fill in: the read, the edit, `swift test` passing. | "Its steps appear as it works: what it read, the edit, and the tests it ran." | 8 s |
| 8 | `reply` | The reply; then the **Changes** pane with the one-line fix in colour. | "When it's done, its reply says what it changed, and Changes shows the edit." | 8 s |
| 9 | `end` | The row says **Done**; the card ticks **Start your first agent**. | "That's your first agent." | 3 s |
| — | — | End card: logo, **Loops**, "docs.agentloops.dev". | — | 3 s |

What changes against today's `scenes/u1.py`: "project" → "folder" (lines 2, 3), the Get
started card (lines 1, 2, 9), the Changes pane in line 8, and a last line of its own. The
words follow the tutorial `docs/tutorials/first-agent.md`; if the window says another name,
the window wins and the tutorial gets an issue.

### 2.2 The steps

| Step | What | Who | Issue |
|---|---|---|---|
| 1 | Write the script (2.1). | Product Owner | this spec |
| 2 | Make `make.sh u1` work on today's app (one app, `Agents` program name, the walk socket, the Get started card), change `u1.py` to the script, take it, look at the contact sheet and Whisper's check. | a lane | child: the take |
| 3 | `upload.py` uploads any scene: a playlist per group (`Loops usage`, `Loops marketing`, `Loops integrations`) on the Loops channel, private, the captions from the `.vtt` (`captions.insert`), a thumbnail from the contact sheet, title "<TITLE> — Loops <version>". | a lane | child: upload any scene |
| 4 | The YouTube sign-in (done 2026-11-12, #4837): the agents' Google account **Loops Agents** (agentloops@fastmail.com) owns the channel **Loops** and the Cloud project `loops-videos`, whose OAuth app is In production; `upload.py --sign-in --no-browser`, the address opened in the agents' own Chrome profile. Alex typed the account's password; an agent did the rest. | Alex, with an agent | child: YouTube sign-in (`alex-todo`) |
| 5 | Upload U1, private. Alex watches it on YouTube and says what to change. | a lane, then Alex | child: rehearsal upload |
| 6 | Write the retro below: what broke at each step, the time and money each cost, and an issue for each fix. | the lane of step 5 | same |

Steps 2, 3 and 4 run at the same time; 5 waits for all three.

Decided: the rehearsal upload is **private** (not unlisted or public), because nothing is
published until Alex has watched it, and an unverified API project's uploads are private
anyway. Alex can overrule.

### 2.3 Done when

- U1 is on YouTube, private, in the playlist `Loops usage`, with English captions and a
  thumbnail, and its link is on #4832.
- `make.sh u1 --upload` makes and uploads it again with no other step.
- The retro (2.4) is written, and each thing that broke has an issue.
- Nothing of Alex's is in any frame (the take's checks pass; a person looks at the contact
  sheet).

### 2.4 Retro

(The lane of step 5 writes this: per step, what broke, the time, the cost, the issue.)

**Step 2, the take (#4835, 2026-11-11).**

- *What broke:*
  - The Get started card: `make.py` put it away before every recording. A scene now keeps
    it with `GET_STARTED = True`.
  - The machine lock (#3490): a fresh root shows "Approve the new machine
    <this Mac's name>?" at the top of the sidebar, and this Mac's name holds Alex's. The
    take's private-words check failed on it (the check worked). The scratch machine is now
    "Sam's Mac" (launch.sh's `HOST_NAME`, #3491), and `make.py` approves its card and
    skips the recovery key card it brings before the recording starts.
  - The end card said "Agents"; it says **Loops** and docs.agentloops.dev (open question 4).
  - The disk: the root's `disk-free-override` has done nothing since the Go host (#1314),
    so the machine's row shows the real disk ("Disk low: 33.5 GB free"). Not private, but
    wrong for a tutorial: #4851.
  - Not broken: one app (#4225) and "folder" (#2617) were already in `make.py` and
    launch.sh. `v.project()` is now `v.add_folder()`.
  - Add Folder…'s panel is the system's, in another process: no walk presses it and no
    shot draws it. Line 2 adds the folder through the socket while the line is said; the
    picture shows the folder arrive and the card tick, not the panel.
- *Time:* build 2.5 min (cache warm), the nine lines' voice 8.5 min (once; kept after),
  each take about 2 min (1 min recording, 40 s Whisper). Three takes, two failed on
  the window's own checks. About 1 h of the lane in all.
- *Cost:* one Claude turn in a scratch folder per take (read, edit, `swift test`): a few
  cents each, on the subscription; the window's meter said $0. The take does not log what
  its agent cost: the root is deleted after it.
- *Length:* 42 s with the end card, not 60 s: the lines are short and the agent quick.

**Steps 3 to 5, the upload (#4838, 2026-11-12).** U1 is
[on YouTube](https://youtu.be/4SCWbBAnMxA): private, in `Loops usage`, English captions, 43 s.

- *What broke:*
  - **A new playlist is 404 for a few seconds.** The first `make.sh u1 --upload` made
    `Loops usage`, and its next call (`playlistItems`) answered 404 playlistNotFound. A
    minute later the same call worked. `upload.py` now waits 5, 10, 20 and 30 s on a 404
    before it fails; the self-test's fake answers 404 twice.
  - **Captions need another scope.** The second run uploaded the video, then
    `captions.insert` answered 403 insufficientPermissions: the sign-in of #4837 asked for
    `youtube`, which has no captions. The sign-in now asks for `youtube.force-ssl` (upload,
    playlists, privacy and captions), and `--preflight` fails a token without it. That
    meant a new consent: the agents' Chrome came up `--incognito` from `cdp.mjs start`
    (signed out), and was started again without it; the account chooser took an agent's
    click; Google's "hasn't verified this app" warning went to Alex by a form (#4840), and
    the consent was done in that window. The captionless take is private and out of the
    playlist, not deleted.
  - **No thumbnail:** `thumbnails.set` answers 403 until the channel is verified by a
    phone number. `upload.py` logs it and goes on, so YouTube picked the frame: #4961
    (`alex-todo`).
  - **The title is a build id:** "Your first agent — Loops v0.18.0-404-g14d039882", from
    `git describe` on the lane's branch: #4962.
  - Not broken: the take itself, three times over. Whisper heard 0% of the script wrong
    each time, the sound test passed, and the contact sheet shows only scratch data (Sam's
    Mac, `/tmp/run-vid-u1`, the `weather` folder).
- *Time:* three runs of `make.sh u1 --upload`: 7, 5 and 3.5 min (the voice and the build
  cached after the first). With the two fixes and the new consent, about 45 min of the
  lane; about 5 min of Alex's (the consent, and a form).
- *Cost:* one Claude turn per take in a scratch folder (a few cents each, on the
  subscription). YouTube: no money; three uploads of the 10,000 daily quota units (an
  upload is about 1,600, a caption 400, a playlist call 50).
- *Alex's watch (2026-11-12):* "Great start! The cadence of the audio is off." Alex wants
  the narration written as a script for the voice, as for film or TV, with directions for
  pauses and tone (#4964), and a title card on each video as well as a closing card (#4965).

**After Alex's watch: the voice and the cards (#4964, #4965, 2026-11-12).**

- *The cadence:* the take spoke at 177 words a minute (about 150 is calm), with no pause in
  a line and 0.06–0.4 s between lines. The fix is a directed script: a small part of SSML
  (`<break>`, `<prosody rate>`, `<emphasis>`, and a tone), the form of the two-column A/V
  script, with the words in the spec and the directions in the scene. Chatterbox reads no
  markup (Turbo reads only sounds such as `[laugh]`), so `voice.py` carries out the marks:
  each phrase said on its own, silence for a pause, and 0.9 s after each line.
- *The voice:* Alex heard nine samples of the same script (Chatterbox with and without the
  directions, Apple's Ava and Zoe reading SSML, and five of Kokoro's built-in voices) and
  chose Kokoro's **Heart**, a built-in voice: no sample of a person's voice, no actor.
  Kokoro has no tone or stress, so those marks change only the pace. Kokoro's own package
  was last released in April 2025, so it runs through `mlx-audio` (MIT, 2026-11-09).
- *The cards:* a title card (the logo, the title, "Loops · How to") fades into the window,
  and the end card has the same look and names the docs page (#4965, PR #4973).
- *The take:* the first one failed its private-words check, as it should: the scratch
  Claude agent followed the app's brief, read the person's memory files, and the window
  showed the `cat` with the home folder. The demo folder's rules (`QUIET` in `make.py`)
  now say to read nothing outside the folder. The second take passed and is
  [on YouTube](https://youtu.be/Y2SCoou-miE), private; the first upload is private and out
  of the playlist. The "Make a recovery key" card shows for a moment at the start.
- *Time:* about 2 h of the lane, most of it the samples; about 10 min of Alex's listening.
- *What the next video needs:* nothing more for a private upload. `make.sh <id> --upload`
  is one step now. A public video still waits on open question 2 (the API audit) and on
  Alex's watch of this one.

## Open questions

1. **The channel:** answered (Alex, 2026-11-11, changed 2026-11-12): a new channel for the
   product, **Loops**, on a Google account of the agents' own (Loops Agents,
   agentloops@fastmail.com, #4837), not under Alex's Google account. Google refuses sign-up
   and sign-in in the app's browser (Chrome for Testing), so its pages open in the agents'
   own Chrome profile (`.agents/signups/cdp.mjs`, not incognito, profile
   `chrome-profile-google`).
2. **Public videos** need the YouTube API audit (Google's compliance review) before uploads
   by the API can be public, or Alex makes each one public by hand. Not needed for the
   rehearsal; decided before the first public video.
3. **Voice mode (M4)** works only in the installed app. Record it on the live app with a
   seeded scratch folder, or wait? After 1.0.
4. **Name on camera:** answered (Alex, 2026-11-11): **Loops**, the App Store name, on the
   channel, the playlists, the titles and the end card. Decided: the narration and captions
   say the names the window shows ("Agents" today), because a usage video must match the
   screen; they change when the app's own name changes. Alex can overrule.
