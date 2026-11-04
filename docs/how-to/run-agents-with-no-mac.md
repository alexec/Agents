---
diataxis: how-to
devices: [web, server]
description: Run Agents with no Mac at all, from a control plane in the cloud, the web page and a GitHub Codespace that runs your agents.
---

# Run Agents with no Mac

You can use Agents with no Mac. A control plane runs on a Linux machine you rent, the web
page is your window, and a GitHub Codespace (or any Linux server) runs your agents. You do
each step in a browser or in a terminal on a Linux machine.

## Before you start

- A Linux machine you rent, with Docker, and a domain of your own. See
  [Run the control plane in the cloud](run-the-control-plane-in-the-cloud.md#before-you-start).
- A GitHub Codespace, or another Linux server, for your agents. It needs `curl` and
  trusted roots (`ca-certificates`). Codespaces have both.
- An account for a runtime, such as a Claude subscription or an Anthropic API key.

## Steps

### Start the control plane

Do the [Steps](run-the-control-plane-in-the-cloud.md#steps) of "Run the control plane in
the cloud" by hand, up to and including **Start it**. Do the `gcloud` steps on any computer
or in Google Cloud Shell. Do not use the three Google Cloud scripts: they run from a Mac.

### Pair the first browser

The first code comes from the control plane's machine.

1. On the control plane's machine, in the folder with `deploy/`:

   ```sh
   docker compose -f deploy/compose.public.yaml exec control /agents-control code --client --browser
   ```

   It prints a code. The code works once, for five minutes. `--browser` makes a code for
   the web page. Without it, the code is for a window on a Mac.
2. In your browser, open `https://agents.example.com/`. Under **Connect this browser to
   your agents**, paste the code and click **Connect**.

The browser is paired. It can do all that a window can. To pair another browser, phone or
tablet, use **Add a Browser…** in this one; see
[Use Agents in a browser](use-agents-in-a-browser.md).

### Add the codespace as a machine

1. On the web page, open **Settings ▸ Machines** and click **Add a Machine…**.
2. Choose **A server** and click **Next**. Click **Copy** to copy the command.
3. Open a terminal in the codespace (in its editor or with `gh codespace ssh`), paste the
   command and run it. It looks like this:

   ```sh
   curl -fsSL https://agents.example.com/v1/install.sh | sh -s -- 'agents-control:2:h:…'
   ```

   The machine then shows under **Machines** on the web page.

   A codespace has no systemd, but its `systemctl` command does not say so, so the command
   says **Started as the systemd user service agents-host.** and starts nothing (#3350).
   Until that is fixed, start the host yourself, in the same terminal:

   ```sh
   ~/.agents-server/bin/current --root ~/.agents-server/root --serve --detach --control-network --host-name "$(hostname)"
   ```

Do the same on any other Linux server. See [Add a machine](add-a-machine.md) for folders
on the machine.

Or, with a GitHub Codespaces machine provider (see
[Set up a cloud machine provider](set-up-a-cloud-machine-provider.md)): on the web page, open
**Settings ▸ Machine providers**, find the codespace and click **Add as Machine…**. The
codespace must be running. The control plane installs Agents on it over `gh`'s ssh and links
the machine to the codespace. The first time, the dialog shows the codespace's host key:
click **Trust and Install**. You do not need a terminal in the codespace.

### Sign a runtime in on the codespace

The installer puts Claude on the machine, but Claude needs a sign-in there. Without a Mac,
no sign-in can come from a Mac. On the web page, click **Sign In…** on the machine's Claude
or Codex row (#3349), or sign it in in the codespace's terminal:

- **With a Claude account:** run `claude`, type `/login`, and do the steps it gives. If
  the codespace has no `claude` command, install it first with
  `npm install -g @anthropic-ai/claude-code`. The sign-in goes in
  `~/.claude/.credentials.json`, where the machine's agents find it.
- **With an API key:** put `ANTHROPIC_API_KEY` in the codespace's environment, such as a
  Codespaces secret, before you run the command from Add a Machine. The host gets the
  key from the terminal it starts in.

For another runtime, use that runtime's own sign-in in the terminal. See
[Runtimes](../reference/runtimes.md).

### Start an agent

On the web page, add a folder on the codespace and start a session in it, as you would on
a Mac. The runtime menu shows the runtimes on the codespace.

### When the codespace stops and starts again

A codespace has no systemd, so its host does not start by itself after a stop (an idle
timeout, or **Stop**). When the codespace's machine is linked to a Codespaces machine
provider, the control plane starts the host over ssh:

- **Start** on the machine starts the codespace, then the host.
- A codespace started from GitHub, not from Agents, has its host started when the control
  plane next lists the provider's codespaces, within 5 minutes.

A machine with no link to a provider (added with the command from **Add a Machine…** only)
is not started. Run that command again in the codespace's terminal, with a new code.

## What is missing for now

- **The command does not start the host on a codespace** (#3350): start it yourself, as
  above.

## Related

- [Run the control plane in the cloud](run-the-control-plane-in-the-cloud.md).
- [Use Agents in a browser](use-agents-in-a-browser.md).
- [Add a machine](add-a-machine.md).
- [Set up a cloud machine provider](set-up-a-cloud-machine-provider.md): GitHub Codespaces
  as a provider.
