---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Pair a Mac, iPhone or iPad with no code by signing in with Google, Apple or GitHub, and turn those sign-ins on for your control plane.
---

# Sign in with Google, Apple or GitHub

A person can pair a new Mac, iPhone or iPad with no code. They sign in with Google, Apple
or GitHub, and the control plane pairs the client as that person. Codes still work, and a
control plane with no provider turned on uses only codes. A browser pairs with a code from a
signed-in client, by your approval with the code it shows (see below), or signs in with your
organisation's own provider.

The control plane uses the app's own Google, Apple and GitHub client ids. You do not register
anything with them. A build that you make from source needs ids of its own: see [Set up Google,
Apple and GitHub sign-in for your own build](set-up-sign-in-for-your-own-build.md).

## Turn a provider on

You must be an admin.

1. Open **Settings ▸ Control plane ▸ Sign-in Providers** (on the web page, **Settings**,
   then **Sign-in Providers** under Control plane).
2. Turn on **Apple**, **Google** or **GitHub**. A provider that this build has no client id
   for says so, and you cannot turn it on.
3. Optional: in **Allowed Google Workspace domains**, type your domains, for example
   `example.com`, and select **Save Domains**. A person with a Workspace account on one of
   these domains can then join as a member with no invite.
4. Optional: in **Allowed GitHub organisations**, type your organisations and select **Save
   Organisations**. Then each GitHub sign-in must be in one of them. This does not let a
   person join with no invite.

## Add a sign-in to yourself

Do this once, on a client that is already paired.

1. Open **Settings ▸ Account** on the Mac, or **Settings ▸ Sign-ins** on an iPhone or iPad.
2. Select **Add a Sign-in…**, then sign in with Apple, Google or GitHub.

The sign-in is now one of yours. You stay one person. To take it off, select **Remove…**
beside it. The web page lists your sign-ins, but cannot add one.

A new person who is not on an allowed domain joins with an invite first. They pair with the
invite's code, then add their sign-in in the same way.

## Pair a new client by signing in

1. On a Mac, open the **Connect** sheet. On an iPhone or iPad, open Agents. Both show the
   sign-in first. To pair with a code, select **Use a Code Instead…**.
2. Type the control plane's address, for example `control.example.com`, and select
   **Continue**.
3. Sign in with a provider that you added to yourself.

With Apple or Google, the client pairs at once. With GitHub, the new client shows a code. On
one of your other clients, a card says **wants to sign in as you**, with your GitHub account and the same
code. Make sure that the codes are the same, then select **Approve**. The request stops
after 10 minutes.

If the address has no provider turned on, the screen goes to the code by itself, and says so.

## Pair a browser by your approval

1. Open the control plane's page in the browser. Under **Sign in with your account**, type the
   email of your Google or Apple sign-in, or your GitHub login, and select **Continue**.
2. The page shows a code.
3. On one of your signed-in clients, a card says **Chrome wants to sign in as you**. The card
   does not show the code. Type the code that the browser shows, and select **Approve**.

The browser pairs as you. The request stops after 10 minutes. You type the code, and do not
only compare it, because anyone can type your email: only someone who sees the browser can
approve it. The page says the same for an email that nobody has, so it tells nobody who has an
account. This needs a provider turned on; with none, use **Add a Browser…**.

## Sign in with your organisation's provider

When your organisation added its own provider (Okta, Entra, Google Workspace with its own
client, or another OIDC provider), its button comes first, by name: **Sign in with Acme
Okta**. The built-in providers come after it, then the code.

1. On a Mac, open the **Connect** sheet and type the control plane's address. On an iPhone
   or iPad, select **Sign In Instead…** and type it. In a browser, open the control plane's
   page, for example `https://agents.example.com/`.
2. Select **Sign in with Acme Okta**. Or select **Use an Email**, type your work email and
   select **Continue**: the control plane finds your organisation's provider.
3. Sign in at the provider. You come back paired, with no code and no Approve.

The control plane runs the sign-in itself, and the client gets a ticket that works once, on
the connection that started it. No token from the provider comes to the client. To add the
provider to yourself on a paired Mac, iPhone or iPad, use **Add a Sign-in…**.

Your organisation can require its provider for its email domain. Then a Google, Apple or
GitHub sign-in at that domain says **Your organisation asks you to sign in with Acme Okta.**,
with the button. If your organisation turns your access off, every client of yours shows only
**Your organisation's sign-in turned your access off.** Your clients stay paired, and open
again by themselves when your organisation turns your access on. See [Org identity](../explanation/org-identity.md).

## Why GitHub asks for Approve

An Apple or Google sign-in carries a nonce. The client makes the nonce from the control
plane's key and the connection, so a sign-in made for one control plane does not work at
another. A GitHub token cannot carry a nonce. So another of your clients must approve each
new GitHub client. The control plane uses the GitHub token once, to find your GitHub account,
and then forgets it.

## If sign-in does not work

- **"No sign-in provider is turned on"**: an admin must turn one on, or you pair with a code.
- **"Nobody on this control plane signs in with this account"**: add the sign-in to yourself
  on a paired client first, or ask an admin for an invite.
- **"… is not available now"**: the control plane cannot reach the provider. Clients that are
  already paired continue to work. Try again later.
- **"The ID token has expired"**: if you just signed in, make sure that the clock on the
  control plane's machine is correct. Five minutes of difference is permitted.
