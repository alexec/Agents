---
diataxis: explanation
description: Why each client belongs to a person and each machine to one user, what an admin sees, and why machines are not shared.
---

# People and machines

A control plane can hold a few people who work together (#994, spec 736). Each person
has their own clients, and each machine (a host or a workspace) belongs to one user.

## The local owner

The first person on a control plane is the **local owner**. They sign in with the control
plane's own key: the codes Agents Host and `agents-control` make are theirs. They are an
**admin**, and they own everything that was there before people came. A control plane
with one person works as it did. Nothing asks them to sign in anywhere, and no account
outside is needed.

## One user per machine

A person reaches only their own machines. The control plane opens a client's channels
only to its person's machines, and a call to another person's machine is answered "no such
host", as for a machine that is not there. Each method of the control plane that names a
machine checks the same.

Machines are not shared, also not to see. A machine runs agents with its user's sign-ins,
keys and files: a second person on it could act as the first. Two people who want to
work on the same code each use their own machine, and git between them.

## What an admin sees

An admin sees every person in **Settings ▸ People**, with their clients by name, and their
machines by name and state (online, offline). Nothing inside another person's machine:
not its projects, its agents or its files. An admin invites people, changes roles and
removes people. A control plane always keeps one admin at least.

## How a machine becomes someone's

- **A code** made on a person's client: the machine is that person's.
- **Approval:** a machine with no code asks to join as a person, and shows a short code.
  That person approves it on one of their clients within 10 minutes. A request that names
  nobody goes to the admins.
- **A workspace provider's start:** the machine is the person's who started it.

## What comes later

Sign-in with Google, Apple or GitHub (#995). Settings that follow a person to each of their
machines, and their secrets. Groups, bots that run team workflows, and links from chat
identities to people. See spec 736.
