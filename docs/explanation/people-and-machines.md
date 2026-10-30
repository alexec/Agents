---
diataxis: explanation
description: Why each client belongs to a person and each machine to one user, what an admin sees, and why machines are not shared.
---

# People and machines

A control plane can hold a few people who work together (#994, spec 736). Each person
has their own clients, and each machine (a machine or a workspace) belongs to one user.

## The local owner

The first person on a control plane is the **local owner**. They sign in with the control
plane's own key: the codes Agents Host and `agents-control` make are theirs. They are an
**admin**, and they own everything that was there before people came. A control plane
with one person works as it did. Nothing asks them to sign in anywhere, and no account
outside is needed.

## One user per machine

A person reaches only their own machines. The control plane opens a client's channels
only to its person's machines, and a call to another person's machine is answered "no such
machine", as for a machine that is not there. Each method of the control plane that names a
machine checks the same.

Machines are not shared, also not to see. A machine runs agents with its user's sign-ins,
keys and files: a second person on it could act as the first. Two people who want to
work on the same code each use their own machine, and git between them.

This holds on the machine too:

- **The direct path.** The Mac window reaches this Mac's machine over a local socket
  (#1118). The machine lets in only a window of its own user, even if a control plane
  were to list another.
- **Lending.** A machine borrows a sign-in or git access only from a machine of the same
  user. A lend made before people came, from another user's machine, is not used.
- **An agent's tools.** `list_sessions`, `read_session`, `message_session` and the leases
  act on the machine they run on. They never reach through the control plane to another
  machine, so an agent acts as its machine's user, and reaches only that user's sessions.
  `start_session` with a `machine` (#2887) is the one exception. It goes through the
  control plane, only to another machine of the same user, and only after that user says
  yes. The agent that started such a session then reaches it, and only it (#2927):
  its `list_sessions`, `read_session`, `message_session`, `wait_for_agents`,
  `stop_session` and `archive_session` go through the control plane to that machine,
  which answers only the agent its own record says started the session. Each machine
  keeps that record in `elsewhere.json` in its data folder.

## What an admin sees

An admin sees every person in **Settings ▸ People**, with their clients by name, and their
machines by name and state (online, offline). Nothing inside another person's machine:
not its folders, its agents or its files. An admin invites people, changes roles and
removes people. A control plane always keeps one admin at least.

## Removing a person

**Remove** first lists what it takes: the person's clients, the machines started for them
by a machine provider, and their other machines. Each started machine is asked for the
work on it that is not pushed (commits not pushed, a branch never pushed, changes not
committed), because Remove deletes it. Within 5 seconds on every copy of the control
plane, their clients are cut off and every machine of theirs leaves. Each started machine
is then stopped and deleted through its provider.

## Older builds

A build from before people came cannot tell people apart. With one person it works as
it did. When a second person joins, the control plane refuses it with "Update Agents to
join this team" (`docs/explanation/versions.md`).

## How a machine becomes someone's

- **A code** made on a person's client: the machine is that person's.
- **Approval:** a machine with no code asks to join as a person, and shows a short code.
  That person approves it on one of their clients within 10 minutes. A request that names
  nobody goes to the admins.
- **A machine provider's start:** the machine is the person's who started it.

## What comes later

Sign-in with Google, Apple or GitHub (#995). Settings that follow a person to each of their
machines, and their secrets. Groups, bots that run team workflows, and links from chat
identities to people. See spec 736.
