---
diataxis: legal
devices: [mac, iphone, ipad, web, server]
description: What Agents keeps, where it keeps it, and what it sends to other services. Agents is local first and collects nothing about you.
---

# Privacy

Last changed: 30 October 2026.

Agents is local first. Your folders, conversations, settings and keys stay on machines
that you control. Agents has no analytics, no tracking and no advertising. The people who
make Agents do not see your data and do not sell it.

## What stays on your machines

- **Your Mac:** Agents Host keeps its records in `~/.agents` and the folders of your
  folders: conversations, workflows, labels, usage numbers and settings. It keeps tokens and
  passwords in the Mac's Keychain.
- **Feature counts (#2165):** each machine counts how many times a day each feature (a
  method of the host or an app tool) is used, and by which client: the Mac, the Remote, the
  web page, an agent or a workflow. It keeps only the counts, never what a call said, for 90
  days in `features-history.json`. Reports ▸ Features shows them to you. They never leave
  your machines.
- **Your Linux servers:** a server that you add keeps the records of its own agents on its
  own disk.
- **Your control plane:** it keeps the list of your hosts, clients and pairings, in the store
  that you choose (a folder on your Mac, or S3 or MinIO of your own). It is yours. You run it
  on your Mac or on a machine of your own.
- **Your iPhone and iPad:** the Remote keeps what it shows you, and a copy of its pairing.

When you delete an agent, a folder or a workflow, the app deletes its records from that
machine.

## What goes to other services

Agents sends data to another service only when you set up an integration that needs it.
Each one sends only what it needs, to that service only:

- **The coding agents (runtimes):** Claude, Codex, Gemini, Antigravity, Grok, Copilot,
  Cursor and OpenCode run on your machine. Each one sends your prompts and the files it reads
  to its own company, under that company's terms. Agents does not see that traffic and does
  not copy it.
- **GitHub, GitLab and Linear:** when you connect one, your host signs in to it and keeps
  the token. It reads and changes issues, pull requests, merge requests and checks for the
  folders you connect, and nothing else.
- **Email:** when you connect a mailbox, your host reads it over IMAP. It never sends mail.
- **MCP servers (connectors):** each server you add gets what your agents send to its tools.
- **Machine providers:** Docker, AWS, Google Cloud, DigitalOcean, Codespaces and Coder get
  the calls that start, stop and make your machines, with the credentials you give.
- **Downloads:** to install a runtime, the app downloads it from nodejs.org, npm, GitHub or
  the company that makes it.
- **Apple:** the Remote uses your own iCloud (CloudKit) to relay messages and send
  notifications to your devices, and Apple Push Notification service for notifications and
  Live Activities. The words of a notification (the folder, the agent and what it needs)
  are sealed with your device's own key, and only your device opens them. A Live Activity
  update carries only the turn's phase and times, never a title or a line of the chat.

[Integrations](reference/integrations.md) lists every integration, what each one talks to
and where its code is.

## The hosted service

If you sign up on the hosted service with GitHub, the service keeps your GitHub user id,
your GitHub login and the date you signed up. It uses your GitHub token one time, to read
your id and login, and then forgets it. Your control plane's records are kept apart from
every other account's, and sealed with a key of their own. **Delete Account** on the
account page stops your control plane and deletes everything it keeps, and the account too.

## Videos on YouTube

The Agents folder makes videos of the app with its own scripts, and uploads them to the
YouTube channel of Agents, which Alex Collins owns. The scripts use one Google account (the
channel's) with the YouTube scope. They upload videos, put them in a playlist and set them
private. Every video is private. The scripts read no other Google data and use the token only
on the Mac that makes the videos. The app that you install never signs in to YouTube or to
Google for you.

## Questions

Open an issue on the folder's GitHub page, or write to the address on Alex Collins's GitHub
profile. A change to this page shows its date at the top.
