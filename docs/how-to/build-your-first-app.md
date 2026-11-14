---
diataxis: how-to
devices: [mac, web]
description: The first time you open Agent Loops, it asks for your idea under "Let's build your idea." An agent then takes you from the idea to the first deploy of an iPhone app or a web service.
---

# Build your first app

The first time you open Agent Loops, it shows one question: **Let's build your idea.** You type
an idea for an app and press **Submit**. Then a plan page shows the tasks from your idea to
your first app, deployed, and an agent does them with you (#5048).

## Before you start

- Agent Loops on this Mac, opened for the first time. See
  [Set up Agent Loops on this Mac](set-up-on-this-mac.md). Or, in a browser, a hosted account
  with one machine. See [Use Agent Loops in a browser](use-agents-in-a-browser.md).
- A GitHub account. You connect it on the plan page.
- For an iPhone app, an Apple Developer Program membership, or the time to join it. For a
  web service, a Google Cloud account. The agent asks for each one when it needs it, on a
  card.

## Who sees the question page

On its own, only a newcomer: a control plane with no folder, on which no agent ever ran. A
new Mac that joins a control plane with work on it, a second browser, and a person who chose
**Open Agent Loops** on the plan page do not see it.

A person who is set up already opens it with **New App…** (#5132):

- On the Mac: **File ▸ New App…** (⇧⌘A), or **New App…** in the command menu (⌘K).
- On the web page: **New App…** in the **+** menu at the top of the folders column, or in
  the command menu (⌘K).

Opened this way, the page has **Cancel** (or press Escape), which goes back to the window as
it was. Each idea you submit this way is a new first-build session of its own.

In a browser on a hosted account, you first add a machine, because an agent needs one.
Then the question page shows.

## 1. Type your idea

1. Open Agent Loops. The window shows the Huddle, the text **Let's build your idea.** and one
   box. The box has no Skip: this is how a first open starts.

   On the Mac, Agent Loops sets itself up behind the page: the control plane, this Mac's host
   and the window's pairing. You can type at once. A line shows under the box only when the
   set-up is slow or fails, with **Try Again** and **Show Details** (and
   **Open Login Items** when macOS wants your approval). See
   [Fix Agent Loops when it won't start](fix-agents-host-not-starting.md).
2. Type your idea. The box shows an example idea, which changes every 4 seconds. Press
   **Tab** to put the example in the box, then change it as you want.

   The examples are:

   | Idea | What the agent makes |
   | --- | --- |
   | An iPhone app that shows the weather where I am | iPhone app |
   | A web page that shows this week's weather for my town | Web service |
   | An iPhone app that reminds me to water my plants | iPhone app |
   | A website for my book club's reading list | Web service |
   | An iPhone app that logs my runs | iPhone app |
   | A web service that emails me a daily summary of my GitHub | Web service |

3. Press **Submit**, or Return. Shift-Return makes a new line. While the set-up is not done
   yet, the page says **Setting up Agent Loops on this Mac…** and goes on when it is done.

## 2. Check what will be built

The plan page shows your idea as its title. Under it, one line says what the agent makes:
*An iPhone app, from agentloops-dev/iphone-app-starter* or *A web service, from
agentloops-dev/web-service-starter*.

- The words of the idea choose. Words such as *iPhone*, *iOS*, *iPad*, *App Store* or
  *TestFlight* choose an iPhone app. Words such as *web*, *website*, *page*, *service*,
  *server*, *API* or *email* choose a web service. The first word that matches wins.
- To make the other kind, choose **Change**. You can do this until the agent starts.
- When no word matches, the page asks **What kind of app is it?**, with **iPhone app** and
  **Web service**. Choose one.
- When the idea names a kind that Agent Loops does not make (a Mac, Android or Windows app, or
  a game), the page says that Agent Loops can start with an iPhone app or a web service. Choose
  one, and the agent builds your idea on it as far as it goes. Or choose **Back** to change
  your idea: your words stay in the box.

## 3. Do the first two tasks

The task list shows each task with its state: **To do**, **Doing**, **Done**, or
**Waits for you**.

| iPhone app | Web service |
| --- | --- |
| 1. Set up the agent runtime | 1. Set up the agent runtime |
| 2. Connect GitHub | 2. Connect GitHub |
| 3. Make the repository from agentloops-dev/iphone-app-starter | 3. Make the repository from agentloops-dev/web-service-starter |
| 4. Join the Apple Developer Program | 4. Set up Google Cloud (Cloud Run) |
| 5. Put the App Store Connect key in the repository's CI | 5. Set up Sentry |
| 6. Set up Sentry | 6. Deploy the first version |
| 7. Send the first build to TestFlight | 7. Approve the first deploy |
| 8. Approve the first build | |

You do the first two tasks on the page. The agent cannot start before they are done.

1. **Set up the agent runtime.** The task shows Claude. Click **Install** when it is not on
   the machine, then **Sign In…**. To use another runtime, choose it from
   **Other Runtime**. See [Sign a runtime in](sign-a-runtime-in.md).
2. **Connect GitHub.** Click **Connect GitHub…** and sign in. See
   [Use GitHub](use-github.md).

Each task ticks itself when it is done. Then the agent starts, in a new folder,
**First build** (`~/.agents/first-build`), with the label `first-build`.

## 4. Answer the agent

The agent's chat shows under the task list, with its prompt bar. The agent follows the
ready-made skill `start-a-new-app`, and ticks each task as it does it. See
[Make a new app's repository](use-github.md#make-a-new-apps-repository).

- A task that needs you shows **Waits for you**: a card in the chat asks you to do a step
  (such as joining the Apple Developer Program), or to give a secret. A secret goes into
  the repository's CI, for this session only.
- The agent makes the repository in your GitHub account and adds it as a folder of its
  own. The first-build session stays in **First build**.
- At the end, the agent sends the first build to TestFlight, or deploys the first version.
  Approve it in **Needs You**. The last task then shows **Done**.

## 5. Go to the usual window

Choose **Open Agent Loops**, at the top right of the plan page, at any time. The usual window
(or page) opens, with the first-build session selected. Its plan strip shows the same task
list. The plan page does not come back by itself. It also goes when you archive the
first-build session.

To make another app later, choose **New App…** (see
[Who sees the question page](#who-sees-the-question-page)), or ask any agent: "Make me an
app that …". The agent follows the same skill.

## If something goes wrong

- **The agent did not start:** the page says why, with **Try Again**.
- **A second client:** when you submit an idea on a second client while a first build is
  there already, the plan page shows that first build.
- **The runtime does not send a plan:** the page shows the agent's tasks as **To do**, and
  the chat under them still shows the agent's work.
