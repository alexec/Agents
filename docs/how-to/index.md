---
diataxis: index
description: Short guides for one task each, for when you know the basics.
---

# How-to guides

One task each, for when you already know your way around the app and want to get
something particular done.

### Setting up

- [Set up Agents on this Mac](set-up-on-this-mac.md): install Agents Host, run your
  agents and the control plane here, and pair the window.
- [Connect a window or phone](connect-a-window-or-phone.md): pair another Mac, an iPhone,
  an iPad or a browser, change what it may do, and forget it.
- [Use Agents in a browser](use-agents-in-a-browser.md): open Agents in Safari or Chrome on
  the Mac that runs Agents Host, pair it once, and forget it.
- [Sign in with Google, Apple or GitHub](sign-in-with-google-apple-or-github.md): pair a
  client with no code, and turn those sign-ins on for your control plane.
- [Set up Google, Apple and GitHub sign-in for your own build](set-up-sign-in-for-your-own-build.md):
  make your own ids for a build from source, and check that sign-in works.
- [Add a machine](add-a-machine.md): make a Linux server, or another Mac, a host of your
  control plane.
- [Invite someone](invite-someone.md): add another person to your control plane, change
  their role, approve a machine that asks to join, and remove a person.
- [Send a folder to a server](send-a-folder-to-a-machine.md): a repository on this Mac,
  with its unpushed branches and uncommitted changes, made a folder on the server, and
  the server's work brought back.
- [Start machines from Agents](start-machines-from-agents.md): let the control plane
  start and stop the machines your servers run on, and press Start on a stopped one.
- [Add a machine provider](add-a-machine-provider.md): a preset, your own commands, a
  tool map, or a provider of your own.
- [Set up a cloud machine provider](set-up-a-cloud-machine-provider.md): add AWS EC2,
  Compute Engine, Cloud Workstations, DigitalOcean, Codespaces or Coder, with the credentials
  each one needs.
- [Turn the relay on or off](turn-the-relay-on-or-off.md): let your iPhone and iPad reach
  your agents away from home through iCloud, and be notified, or stop it.
- [Run the control plane in the cloud](run-the-control-plane-in-the-cloud.md): on a
  machine you rent, at your own domain with a public certificate.
- [Run the control plane as several copies](run-several-copies.md): over one bucket,
  behind a load balancer, so it stays up when your Mac sleeps.
- [Move an existing set-up across](move-an-existing-set-up.md): bring the earlier app's
  agents, devices and servers to a control plane, once.
- [Back up and restore a machine](back-up-and-restore.md): keep a fixed number of backups
  of a machine's agents and conversations in a folder, and restore one on a new machine.
- [Back up and restore a control plane](back-up-a-control-plane.md): its store, key,
  secrets key and certificate in one folder, restored so that every device stays paired.
- [Release Agents Host](release-agents-host.md): publish the Developer ID download on
  GitHub by tagging main, and set up its signing secrets once.
- [Fix Agents Host when it won't start](fix-agents-host-not-starting.md): see why a login
  item isn't running, Repair it, and send diagnostics with a report.

### Folders

- [Add a folder](add-a-folder.md): add a folder or clone a Git URL, and archive a
  folder you are done with.
- [Start an agent in its own worktree](start-in-a-worktree.md): give an agent its own
  checkout and branch.
- [Give an agent more folders and connectors](give-an-agent-more-folders.md): let one
  agent work across two repositories, or reach a connector only it needs.

### Agents

- [Choose a runtime, model and mode](choose-runtime-model-mode.md): what an agent runs
  on, and the meter for its context and cost.
- [Use Auto](use-auto.md): start a session on Auto, choose which runtimes it uses and in
  what order, and read or change what each value is on each runtime.
- [Pick up a conversation started somewhere else](pick-up-a-conversation.md): carry on
  in Agents with one you began in Terminal, or delete one.
- [Answer a question or a permission request](answer-a-question.md): from the Mac, the
  iPhone or iPad, or a notification.
- [Read a chat](read-a-chat.md): open a chat at its latest message, follow the plan card,
  and show or hide the agent's thoughts.
- [Find in a chat or a session](find-in-a-chat-or-a-session.md): find words in the open
  chat with Find in Chat, or find a session by what was said in it.
- [Send a prompt while an agent is working](send-while-an-agent-works.md): let it wait
  its turn, or put it into the running turn with **Send now**.
- [See what needs you from your Home screen](see-what-needs-you-from-your-home-screen.md):
  the number of sessions waiting on you, and a tap that opens one.
- [Follow a turn on the Lock Screen](follow-a-turn-on-the-lock-screen.md): follow a turn you
  sent from the iPhone or iPad on the Lock Screen and in the Dynamic Island, and turn this off.
- [Watch an agent's background work](watch-background-work.md): the shells and
  subagents it runs in the background, their output, and **Stop**.
- [Review changes and approvals](review-changes-and-approvals.md): read a change that waits
  for your OK on its Review page, and answer it from the page, the card or Needs You.
- [Use a shell in an agent's folder](use-a-shell.md): the Terminal pane, one shell to a
  tab.
- [Attach files and pictures to a prompt](attach-files.md): drag, paste, the paperclip,
  or an @ mention.
- [Read an agent's changes](read-an-agents-changes.md): the Changes pane, edits in the
  conversation, and the files pane.
- [Follow a live document](follow-a-live-document.md): watch a document take shape as an
  agent writes it, and type on it yourself.
- [Look at an HTML page an agent wrote](look-at-an-html-page.md): a report or wireframe as a
  page, with its stylesheet and pictures, and what it is not allowed to do.
- [Edit files](edit-files.md): open a file in an agent's folder, type in it (it saves by
  itself), and see the problems and completions from the file's language server.
- [Use the Simulator pane](use-the-simulator-pane.md): see an iOS simulator on the
  session's Mac, boot it or shut it down, and tap on its screen, from any client.
- [Open a session or a folder in its own window](open-in-its-own-window.md): a window of
  its own on the Mac, a scene of its own on an iPad, or a tab of its own on the web page.
- [Stop and archive agents](archive-and-stop.md): what each does, and what each
  keeps.
- [Mute the notifications for a session](mute-notifications.md): no alerts for a session
  or a workflow's runs, which still go under Needs You and on the badge.
- [Sign a runtime in](sign-a-runtime-in.md): sign Claude Code, Codex, Copilot, Cursor, Grok
  or Antigravity in or out from the app, and give Gemini its key.
- [Assess a runtime](assess-a-runtime.md): have an agent on a runtime work through the app's
  tools, and read the app's own score of it.
- [Share skills, instructions and connectors with every agent](share-skills-across-agents.md):
  put them in `~/.agents` once, for every runtime and folder.
- [Add a skill from a catalogue](add-a-skill-from-a-catalogue.md): search skills.sh, look
  before it goes in, and add it for yourself or to a folder.
- [Choose marketplaces](choose-marketplaces.md): which marketplaces Add Connector… and Add
  skill… search, and adding your own, such as your company's MCP registry.
- [Add a connector from the registry](add-a-connector-from-the-registry.md): search
  GitHub's MCP registry or another, see what would run, and add it for yourself or to a folder. Secrets stay
  in your own `secrets.env`.
- [Add a connector by hand](add-a-connector-by-hand.md): a local command or a remote
  URL that is not on the registry, verified to answer before anything is written.
- [Share one copy of a local connector](share-one-copy-of-a-local-connector.md): mark a
  connector `"hosted": true` so the app runs it once per host for every agent and workflow.
- [Sign in to a connector](sign-in-to-a-connector.md): a remote connector that asks for
  OAuth, such as GitHub's, signed in to in your browser so agents start with it.
- [Keep going when a runtime runs out](keep-going-when-a-runtime-runs-out.md): see which
  runtimes are out, and continue a chat's work in a new chat on another.
- [See usage, cost and time](see-usage-cost-and-time.md): open the Cost, Tokens and Time
  pages, read their charts, and see how much of a runtime's allowance is used.
- [Limit what agents spend](limit-spending.md): the Spending page, and a limit per agent
  or per day.

### Servers

- [Add a machine](add-a-machine.md): make a Linux server a host of your control plane.
- [Send a folder to a server](send-a-folder-to-a-machine.md): a repository on this Mac,
  with its unpushed branches and uncommitted changes, made a folder on the server, and
  the server's work brought back.

### Automation

- [Set up a workflow](set-up-a-workflow.md): start agents on a schedule, or when another
  agent finishes, stops or asks.
- [Read a workflow's page](read-a-workflows-page.md): see whether a workflow runs and why
  not, what each run did and why it started, and run it now.
- [Start a workflow from an MCP event](start-a-workflow-from-an-mcp-event.md): an agent
  each time a connector reports something, such as a pull request's checks failing.
- [Use GitHub](use-github.md): connect GitHub once, set up a folder's Tasks, Code review
  and CI, work with pull requests and issues on their pages, and use CodeRabbit.
- [Use GitLab](use-gitlab.md): connect GitLab with the gitlab.com sign-in or an access
  token, set up a folder from it, and work with merge requests, issues and pipelines.
- [Use Linear issues](use-linear-issues.md): Linear's own tools, and an agent when an
  issue is opened, labelled, commented on or closed.
- [Wait for mail](wait-for-mail.md): a mailbox for agents, the Mail page, and sign-up codes
  given to the session that waits for them.
- [Pin a page to a folder](pin-a-page-to-a-folder.md): a document or an HTML page
  under its folder in the sidebar, live as it changes.
- [Hand files to a workflow](hand-files-to-a-workflow.md): drop a file into a folder's
  drop box and have a workflow work on it.
- [Have an agent wait for something](wait-for-something.md): checks passing, another
  agent finishing or the Mac waking, and agents telling each other.
