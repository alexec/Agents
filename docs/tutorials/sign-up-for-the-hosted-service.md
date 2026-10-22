---
diataxis: tutorial
devices: [web]
description: Sign up for the hosted service with GitHub, get a control plane of your own, open it in a second browser, and delete the account.
---

# Sign up for the hosted service

In this tutorial you sign up for the hosted service with your GitHub account. You get a
control plane of your own, and the browser you signed up in connects to it. Then you use
the account page to open the same control plane in a second browser. At the end you learn
how to delete the account. It takes about five minutes.

The hosted service is the shortest way in. You need only a browser: you type no command
and you hold no key. See [Direction](../explanation/direction.md) for why it exists.

**What you'll have at the end:** an account on the hosted service, a control plane at an
address of its own, and two browsers paired with it.

## Before you start

- A GitHub account. One GitHub account gets one account on the service.
- The address of the hosted service, such as `agentloops.dev`. Whoever runs the service
  gives it to you. To run one yourself, see
  [Run the hosted service](../how-to/run-the-hosted-service.md).
- Two browsers, for step 4. A second browser on the same computer is enough.

## 1. Sign up with GitHub

1. Open the address of the hosted service in your browser.

   The page says **Agents**, and under it: "Sign up and you get a control plane of your
   own. You type no command and hold no key."
2. Click **Sign Up with GitHub**.

   If the page says **Sign-up is not open yet.**, the service is not ready to take
   accounts. Ask whoever runs it.
3. GitHub asks you to sign in and to let the app see who you are. Approve it.

   The service reads only your GitHub id and login, once. Then it forgets the GitHub token.
   See [Privacy](../privacy.md#the-hosted-service) for what it keeps.

## 2. See your control plane connect

The first time you sign in, the service makes your account and starts your control plane.
Then it sends this browser to the control plane, at an address of its own, such as
`k3v9x0qa7b.cp.agentloops.dev`. The first part, ten letters and digits, is your account's
name. It is random, so it says nothing about who you are.

The address carries a pairing code, and the page pairs itself with it. You type nothing.
The page removes the code from the address before anything else reads it, so Back and the
browser's history do not keep it.

The code works once, for five minutes. If the page asks you to **Connect this browser to
your agents**, the code was used or too old: go to step 3 and click **Open in This
Browser**.

## 3. Open the account page

1. Open the address of the hosted service again, in the same browser.

   You are still signed in, so you go straight to **Your account**. A sign-in lasts 30
   days in this browser.
2. Read what the page shows:
   - **Signed in with GitHub as** your GitHub login.
   - **Your control plane is at** its address. Each browser, Mac and phone you use pairs
     with it once.
   - **Open in This Browser** and **Sign Out**.
   - **Delete Account**, at the bottom.

Your control plane stops when nothing has used it for 15 minutes, and starts again at the
next request. This keeps the service small. A machine or a browser that stays connected
keeps it running. So the first page after a quiet time can take a moment longer.

## 4. Open your control plane in a second browser

A browser pairs only once, and only with a code. The account page gives a new code to each
browser that signs in, so you do not copy a code from one browser to the other.

1. In the second browser, open the address of the hosted service.
2. Click **Sign Up with GitHub**. You signed up before, so the same button signs you in:
   "Signed up before? The same button signs you in." You go to **Your account**.
3. Click **Open in This Browser**.

   The service makes a new pairing code and sends this browser to your control plane with
   it. The page pairs itself, as in step 2.

If the account page says **Your control plane could not start just now. Try Open in This
Browser again in a moment.**, wait a moment and click **Open in This Browser** again.

Each browser keeps a key of its own, which can't be copied out of it. If you clear the
site's data, or close a private window, the browser loses its key. Click **Open in This
Browser** again to pair it again.

## 5. Delete the account

Do this step only when you want to stop using the service. You cannot undo it.

**Delete Account** stops your control plane and deletes everything it keeps: your people,
clients, machines and settings, and its control key. Your machines and their agents are
not deleted; they stay where they are. The service asks for the account's name first, so
that one wrong click deletes nothing.

1. On **Your account**, find the account's name in the **Delete Account** section. It is
   the ten letters and digits at the start of your control plane's address.
2. Type the name in the box beside **Delete Account**.
3. Click **Delete Account**.

   The page says **Your account and its control plane are deleted.** You are signed out.
   Every paired browser loses its control plane: the address no longer answers.

If you type a different name, the page tells you to type the account's name, and shows the
name. It deletes nothing. If the page says **Not everything could be deleted. Delete the
account again.**, click **Delete Account** again.

The same GitHub account can sign up again later. It gets a new, empty control plane at a
new address.

## What you learned

- **Sign Up with GitHub** makes the account and its control plane, and pairs the first
  browser with nothing to type.
- The same button signs you in again, and **Your account** shows where your control plane
  is.
- **Open in This Browser** pairs another browser, after it signs in.
- **Delete Account** deletes the control plane and all it keeps, but not your machines.

## Where next

- [Use Agents in a browser](../how-to/use-agents-in-a-browser.md): what the web page can
  do.
- [The control plane](../explanation/control-plane.md): what your control plane does, and
  why every client is trusted alike.
- [Run the hosted service](../how-to/run-the-hosted-service.md): for whoever runs the
  service.
- [Terms](../terms.md) and [Privacy](../privacy.md).
