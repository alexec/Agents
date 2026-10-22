---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Invite another person to your control plane, let your organisation's provider add people by SCIM, change their role, approve a machine that asks to join, and remove a person.
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

A person joins with an invite code. After that, they can add a Google, Apple or GitHub
sign-in to themselves, and pair more clients by signing in (see [Sign in with Google, Apple
or GitHub](sign-in-with-google-apple-or-github.md)):

- **Apple and GitHub:** the person needs an invite first. Then they add the sign-in.
- **Google:** a person with an account on one of the **Allowed Google Workspace domains**
  joins with no invite. Any other Google account needs an invite first.
- **GitHub organisations:** when an admin allows organisations, only a member of one of
  them can sign in with GitHub. This does not let a person join with no invite.

A build of Agents from source needs its own ids for these: see [Set up Google, Apple and
GitHub sign-in for your own build](set-up-sign-in-for-your-own-build.md).

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

## Who may join, and SCIM

With an [org provider](../explanation/org-identity.md) (Okta, Entra, Google Workspace), an
admin chooses **Who may join** for it: **Only by invite**, **Anyone the provider signs in**,
or **Only people from SCIM**. An invite works with each of them.

With SCIM, your organisation's provider adds people for you, and you send no invites:

1. Turn on SCIM for the provider (`scim/set`), and make a SCIM token
   (`scim/tokens/make`). Copy the token and the SCIM URL: the token is shown once.
2. In Okta or Entra, add the SCIM URL and the token to the app, and map `externalId` to the
   person's id there: `user.id` in Okta, `objectId` in Entra.
3. Assign the app to people or groups at the provider. They show in People as **Waiting for
   first sign-in**, and join when they first sign in with the provider.

When the provider deactivates a person, they are suspended within 5 seconds: their
clients are cut off and their machines stop their work, and nothing is deleted. When the
provider deletes a person, an admin is asked to remove them (`people/removeRequests`).

## Change a role

In **Settings ▸ People**, choose **Admin** or **Member** beside the person. A control plane
always keeps one admin at least: the last admin can't be made a member.

A SCIM group can **Give the admin role** (`groups/setRole`). Its members' roles are then
set by the provider: change them in the provider's group, not here.

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
