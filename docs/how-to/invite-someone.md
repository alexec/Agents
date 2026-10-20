---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Invite another person to your control plane, change their role, approve a machine that asks to join, and remove a person.
---

# Invite someone

A control plane can have more than one person (#994). Each person has their own clients
and their own machines. A person reaches only their own machines: another person's
machine is not there for them. When you are the only person, nothing changes. You are the
**local owner** and an **admin**, and you own every client and every machine.

See [People and machines](../explanation/people-and-machines.md) for why.

## Before you start

- A client paired with your control plane, as an admin. The local owner is an admin.
- The other person has Agents on a Mac, an iPhone or an iPad.

Sign-in with Google, Apple or GitHub comes later (#995). Until then, a person joins with an
invite code.

## Invite a person

1. Open **Settings ▸ People**.
2. Click **Invite a Person…**.
3. Type their **Name**, and choose **Member** or **Admin**. A member sees only their own
   clients and machines. An admin also sees everyone in People, and can invite, change
   roles and remove.
4. Click **Invite**. The sheet shows a code. Click **Copy**, and send the code to the person.

   The code works **once**, for **7 days**.
5. The person pastes the code where Agents asks for a code: in the Mac window when it
   starts, or on the Remote's pairing screen. That client is their first one. They are
   now in People.

A person pairs more clients (another Mac, a phone, a browser) with codes made on a client
they already have, as you do. Those clients are theirs.

## Change a role

In **Settings ▸ People**, choose **Admin** or **Member** beside the person. A control plane
always keeps one admin at least: the last admin can't be made a member.

## Approve a machine that asks to join

A machine can join without a code. In **Settings ▸ People**, under your own row, copy the
line under **Add a machine without a code**, and run it on the server. The server shows
a short code, and waits.

On each of your clients, a card says **‹name› wants to join as you**, with the code.

1. Check that the machine shows the same code.
2. Click **Approve**. The machine joins as yours, and is in your machines list.

Click **Deny** if you did not ask for it. A request that nobody approves ends after
10 minutes. A request that names no person goes to the admins.

## Remove a person

1. In **Settings ▸ People**, click **Remove…** beside the person.
2. Read what goes: their clients are cut off at once, and their machines leave the control
   plane. Nothing on their machines is deleted.
3. Click **Remove**.

The codes they made, and the invite they joined with, work no more. To let them back,
invite them again. You can't remove yourself or the local owner.
