---
description: The first open of Agents asks one question, "What do you want to build?", then shows a plan page with the task list for an iPhone app or a web service, and an agent with the start-a-new-app skill takes the person from the idea to the first approved deploy (#5048).
---

# What do you want to build? (#5048)

Epic #5048, feature `feature:first-build`, milestone `1.0 Public release`. Spike #5049
wrote this spec. Docs only: the epic's children build it.

## The question

A person opens Agents for the first time. What do they see, and how do they get from that
first look to their first app, deployed, with nothing set up before?

Alex's idea (2026-11-12): one question, **What do you want to build?** The person types an
idea and presses Submit. An agent walks them through the accounts, the agent runtime, the
repository and the deploy.

## Today

- **Mac, first open (#4226).** `ContentView` shows `FirstOpenView` while
  `model.needsFirstRun` is true: no control plane yet. In the one app it asks nothing: it
  sets up the control plane on this Mac and pairs the window, with the Huddle (the Blobs)
  above one progress line. A step that fails shows one line with **Try Again** and **Show
  Details**. When the control plane is on another machine, it connects with a code or a
  sign-in. Then the usual window takes its place.
- **The Get started card (#982),** Mac only. `GetStarted` (AgentsKitCore) ticks five steps
  from real state: *Set up Agents on this Mac*, *Install an agent runtime*, *Add a folder*,
  *Start your first agent* and the optional *Pair a phone or browser*.
  `AppModel+GetStarted.swift` shows it once the lists have come in, never to a person who
  is set up already (`card(kept: nil, …)`), and keeps only `showing` or `gone` in
  `WindowDefaults`. While it shows, its runtime step is the install offer.
- **The achievements (#984),** kept on the host, drawn on the Achievements page (#1067) on
  the Mac and the web page (`AppModel+Achievements.swift`, `Web/src/model/achievements.ts`):
  first agent, first pairing, first answer away from the Mac, first workflow, first cloud
  machine, first pull request landed with nobody watching, five agents at once. A one-time
  card shows each one earned while the client looks.
- **A new app (#3656).** The ready-made skill `start-a-new-app` (#3712) goes from "make me an
  app" to the approved first deploy: the kind and the name, `make_app_repository` from
  `alexec/iphone-app-starter` or `alexec/web-service-starter` (#4561), the gates, Apple,
  Google Cloud and Sentry, then `v0.1.0` and the approval in **Needs You**. The brief names
  the skill, `make_app_repository` and the CI tools **only where GitHub is connected**
  (`Go/internal/agentsd/brief.go`, `toolsBrief`).
- **An agent's plan.** An agent's task list is on the wire now: `Agent.plans`, each a `Plan`
  of `PlanEntry` (`content`, `status`: `pending`, `in_progress`, `completed`). The chat's plan
  strip draws the plan in force (#341, #776; `Web/src/model/currentPlan.ts`,
  `Model/CurrentPlan.swift`). Claude's adapter sends its to-do list as this plan.
- **A runtime** is installed and signed in by the clients with `runtimes/install`,
  `runtimes/signInStart`, `runtimes/signInFinish` and `runtimes/signInKey`.
- **No folder is made for you (#2134).** An agent starts in a folder (`StartRequest.cwd`).

## What the person sees

### 1. The question page

The whole window (or the whole web page): no sidebar, no toolbar, no checklist.

- The Huddle (the blob icon), as `FirstOpenView` draws it, with `promptFocused` on while the
  box has focus, so the Blobs look at it.
- Under it, the hero text **What do you want to build?** in the largest type step.
- One prompt box, several lines high, with **Submit** (Return submits, Shift-Return makes a
  new line). Submit is off while the box is empty.
- The box's placeholder rotates through the ideas below, one every 4 seconds, with a cross
  fade. It stops on the one it shows when the person types, and starts again when the box
  is empty. With Reduce Motion on, it changes with no fade. Tab puts the idea that shows
  into the box, to change it.
- **No way past it (Alex, 2026-11-12, #5049).** The page has no Skip and no "I have a
  project already": a newcomer's first open is the question page. A person who is set up
  already never sees it (section 9).

### 2. The ideas, and their starters

Each idea names its starter, so a person who takes one gets the plan page with no doubt.

| Idea | Starter |
| --- | --- |
| An iPhone app that shows the weather where I am | `iphone-app` |
| A web page that shows this week's weather for my town | `web-service` |
| An iPhone app that reminds me to water my plants | `iphone-app` |
| A website for my book club's reading list | `web-service` |
| An iPhone app that logs my runs | `iphone-app` |
| A web service that emails me a daily summary of my GitHub | `web-service` |

Decided: the epic's six ideas, unchanged, half for each starter, in turn, because each one
is small enough for a first build, and each names its kind of app in its first words. Alex
can overrule. The list is a constant in each client (Swift and TypeScript, the same order),
held to one fixture, `Fixtures/web/first-build/ideas.json`, as other ported rules are.

### 3. How an idea picks a starter

Decided: **the client picks a starter from the words, and the person can change it on the
plan page**, because the plan page must show the right task list at once, before any agent
can run (there is no runtime yet), and a classifier or the agent's own question would need
one. Alex can overrule.

- An idea from the list keeps its own starter.
- Typed words: `iphone`, `ios`, `ipad`, `app store` or `testflight` pick `iphone-app`;
  `web`, `website`, `site`, `page`, `service`, `server`, `api` or `email` pick
  `web-service`. The first word that matches wins. A bare "app" picks nothing.
- No match: the plan page asks with its own control, **iPhone app** or **Web service**, with
  neither chosen, and the task list shows when the person chooses.
- The rule is one pure function in each client (`FirstBuild.starter(for:)` in AgentsKitCore,
  `firstBuildStarter` in `Web/src/model/`), held to the same fixture.
- The agent gets the starter in its first prompt, so the skill skips its first question
  (it skips what the person answered already). **Both** is not offered here: a first build
  is one app. The skill still offers **Both** to a person who asks for a new app later.

### 4. An idea that fits neither starter

Decided: **the plan page says what it can build, and the person chooses**, because a
refusal on the first screen would end the first open. Alex can overrule.

When the words name a kind the starters do not make (`mac`, `macos`, `android`, `game`,
`windows`, `desktop`), the plan page says, above the choice: *Agents can start with an
iPhone app or a web service. Choose one, and the agent builds your idea on it as far as it
goes.* The person chooses one of the two, or **Back** to the question page with their
words still in the box. The agent gets the idea as it was typed, with the starter chosen.

### 5. The plan page

Submit replaces the question page with the plan page, in the same window (or page), still
with no sidebar or toolbar:

- **What will be built:** the idea, as typed, as the page's title, and under it the starter
  in one line: *An iPhone app, from alexec/iphone-app-starter* or *A web service, from
  alexec/web-service-starter*, with **Change** beside it (the same two choices as above)
  until the agent has started.
- **The task list:** the tasks of that starter (below), in order, each with its state:
  to do, doing (a spinner), done (a tick), or waits for you (the attention tint).
- **Under the list, the agent's chat:** the first-build session's transcript and its cards
  (`hand_to_person`, `ask_secret`, `ask_question`), so each step that needs the person is
  answered here. The prompt bar is the session's own.
- **Open Agents** (top right): the usual window, with the first-build session selected.
  The plan page does not come back on its own after that; the session's plan strip shows
  the same list.

Decided: **the plan page is a view of the first-build session, not a record of its own**,
because the session already keeps the transcript, the cards and the plan on every client,
and a person who leaves finds it in the session list. Alex can overrule. The session has
the label `first-build`. The plan page shows while the window has not yet been taken to the
usual window by **Open Agents**, and the first-build session is not archived; on the web
page, the same, kept in `localStorage` as the achievements' cards are.

### 6. The two task lists

The first two tasks are the client's, done on the plan page before the agent can start,
because an agent cannot run without a runtime, and the skill and its tools are in the brief
only where GitHub is connected. The rest are the agent's.

**iPhone app** (`iphone-app`):

| # | Task | Who | Done when |
| --- | --- | --- | --- |
| 1 | Set up the agent runtime | the client | a runtime on the machine is installed and not signed out |
| 2 | Connect GitHub | the client | the `github` connector is connected |
| 3 | Make the repository from alexec/iphone-app-starter | agent | the skill's step 2 and 3 (repository, gates) |
| 4 | Join the Apple Developer Program | agent, the person's hands | step 4.1 |
| 5 | Put the App Store Connect key in the repository's CI | agent | steps 4.2 to 4.7 |
| 6 | Set up Sentry | agent | step 6 |
| 7 | Send the first build to TestFlight | agent | step 7.1 |
| 8 | Approve the first build | the person | step 7.2 and 7.3: the run succeeded |

**Web service** (`web-service`):

| # | Task | Who | Done when |
| --- | --- | --- | --- |
| 1 | Set up the agent runtime | the client | as above |
| 2 | Connect GitHub | the client | as above |
| 3 | Make the repository from alexec/web-service-starter | agent | skill steps 2 and 3 |
| 4 | Set up Google Cloud (Cloud Run) | agent, the person's hands | step 5 |
| 5 | Set up Sentry | agent | step 6 |
| 6 | Deploy the first version | agent | step 7.1 |
| 7 | Approve the first deploy | the person | steps 7.2 and 7.3 |

How the states are read:

- **Tasks 1 and 2** are ticked from real state, as the Get started card ticks its steps:
  `runtimes/list` and the `github` connector's status. Each shows its control inline while
  it is not done: task 1 installs and signs in the runtime with the existing methods
  (Claude by default, a menu of the other runtimes beside it); task 2 opens the existing
  **Connect GitHub** sheet. On the web page, task 1 does the same on the machine the
  session will run on.
- **The agent's tasks** are its plan. Decided: **the skill writes the task list as its plan
  (the runtime's to-do list, `Agent.plans` on the wire), with these exact words, and ticks
  each as it goes**, because the wire, the clients and the plan strip carry plans already,
  so the page needs no new record. Alex can overrule. The plan page matches each plan entry
  to its task by its words; the skill's plan has tasks 1 and 2 as `completed`, so the
  plan and the page are the same list. Until the agent's first plan comes in, the page
  shows the agent's tasks as to do. A task whose step is a `hand_to_person` or `ask_secret`
  card waiting shows **waits for you**.
- A runtime that sends no plan still works: the page then shows the agent's tasks as to do
  with the agent's chat under them, and the last task is ticked by the deploy's run
  (`run.completed`, as the skill reads it). #5052 makes the skill write the plan.

### 7. How the agent starts

Decided: **a new daemon method, `firstBuild/start`, starts the agent**, because the Mac
window and the web page must start it the same way (principle 1) and the folder it starts
in is the host's to make. Alex can overrule.

- **Params:** the idea (the words, as typed), the starter (`iphone-app` or `web-service`)
  and the runtime (task 1's).
- **The folder:** Decided: the host makes an empty folder, `~/.agents/first-build`, an ordinary folder, not a repository, added as the
  folder **First build**, because no folder is made for a person otherwise (#2134), and
  `make_app_repository` then clones the app's repository beside the person's other clones
  and adds it as a folder of its own. The session stays in **First build**; the skill
  already works on a new folder from another one (its Sentry helper). Alex can overrule.
- **The prompt:** one the host writes, so both clients send the same:
  `Build my first app with the start-a-new-app skill. The idea: <idea>. The kind: <iPhone
  app|Web service>; the starter: <starter>. Keep the first-build task list as your plan.`
- **The label** `first-build`, so the plan page, and a second client, find the session.
- **It answers** with the session's id. It refuses when a first-build session that is not
  archived is there already, and says its id, so a second Submit (or a second client)
  opens the same plan page.

### 8. The order with FirstOpenView (#4226)

**The question page shows at once, with the set-up behind it (Alex, 2026-11-12, #5049).**

- On the one app's first open (`HostScenes.firstOpen` is there), `ContentView` shows the
  question page where it shows `FirstOpenView` now, and runs `firstOpen.run(pair:)` behind
  it: the control plane on this Mac, and the window's pairing. The person can type at once.
- **Submit waits for the set-up.** While it runs, Submit keeps the words and shows *Setting
  up Agents on this Mac…* under the box; the plan page comes when the window is paired.
- **The set-up shows only when it is slow or fails:** one line under the box, in the
  supporting type step, after 5 seconds of work (`FirstOpen.step`'s `.working` words), or
  the failure line with **Try Again** and **Show Details** (and **Open Login Items** when
  macOS wants it), as `FirstOpenView` draws them now. The box keeps its words.
- **The control plane on another machine** (`HostScenes.firstOpen` is nil, or its step is
  `.elsewhere`): `FirstOpenView` stays as it is, to connect with a code or a sign-in. Once
  connected, section 9 says whether the question page shows.
- The web page has no such set-up: a browser signs in to its control plane first, as now.

### 9. Who sees the question page

Decided: **only a newcomer: the control plane has no folder and no agent has ever run on
it**, as the Get started card's rule (`card(kept: nil, …)`, #982), because a person who is
set up already must never be sent back to a first screen. Alex can overrule.

- **A new Mac joining a control plane that has work** (the control plane is on another
  machine), **a second browser**, or a person who answered **Open Agents**: never the
  question page.
- **The web page, hosted, with no machine yet** (a person who starts in a browser): the
  steps of "From nothing to working" (direction.md) come first, as now: a control plane,
  then a machine. The question page shows once a machine is there, because an agent needs
  one.
- **From New, later:** Decided: no entry in New, because a person who knows Agents types "make
  me an app that …" in any session, and the brief sends the agent to the same skill. Alex
  can overrule.

### 10. The Get started card and the achievements

**The Get started card is removed (Alex, 2026-11-12, #5049).** The plan page does its work
for a newcomer, and a person set up already never saw the card (`card(kept: nil, …)`).
#5057 removes `GetStarted`, `GetStartedCard`, `AppModel+GetStarted.swift` and their
tests, and the `getStarted` keys in `WindowDefaults`. The install offer, which waits on the
card now (`weighInstallOffer`'s `getStartedCard == .gone`), then weighs as for a person set
up already; the plan page's runtime task is a newcomer's install offer. The card's
`hasSeenAgentRun` is not needed: *First agent started* is an achievement on the host.

Decided: **the achievements stay as they are**, because each one is a step past the first
app (a workflow, a cloud machine, five agents at once), and *First agent started* is
earned by the first build itself, so its card is the first good news after the plan page.
Alex can overrule.

## Alex's answers

Asked on 2026-11-12 with a form (#5049):

- **The order:** the question page at once, with `FirstOpenView`'s set-up behind it
  (section 8).
- **A way past the question page:** none; the Get started card is removed (sections 1
  and 10).

## Principles (direction.md)

- **1, nothing relies on the Mac:** the web page has the same two pages, and
  `firstBuild/start` is the host's, so both clients start the same agent. The Remote does
  not have them (tier Mac + web): it pairs to a set-up that is there already.
- **2 and 3, the Mac download:** the question page comes on the single-user Mac, which has
  no sign-in; in a browser, after the hosted sign-up, as now.
- **5, customers bring their own:** the runtime, GitHub, Apple, Google Cloud and Sentry
  accounts are all the person's own, made by them, on cards.
- **6, the control plane holds nothing it could misuse:** the idea and the session are on the
  machine; the control plane only routes them. The secrets go from a session-only form to
  the repository's CI, as in #3656.
- **7, keep nothing:** no new record: the plan page reads the session, and the client keeps
  only whether it has left the plan page.

## Clients

Tier **Mac + web** (#2796, decided on #5048). The Remote: `remote: tier mac+web`. The
question page and the plan page are new screens: their PRs wait for Alex (#2811, #3474).

## The plan (the epic's children)

| Step | Child | Level | Blocked by |
| --- | --- | --- | --- |
| 1 | #5049 this spike | spike | — |
| 2 | #5050 Mac: the question page | story | #5049 |
| 2 | #5051 web: the question page | story | #5049 |
| 2 | #5052 `start-a-new-app`: the first-build task list as its plan | task | #5049 |
| 2 | #5056 `firstBuild/start`: the folder, the prompt, the label (filed by this spike) | task | #5049 |
| 3 | #5053 Mac: the plan page, and the agent starts | story | #5050, #5052, #5056 |
| 3 | #5054 web: the plan page, and the agent starts | story | #5051, #5052, #5056 |
| 4 | #5057 Mac: remove the Get started card (filed by this spike) | story | #5053 |
| 4 | #5055 docs, the parity table and the feature matrix | task | #5053, #5054 |
