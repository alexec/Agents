---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Make your own Apple, Google and GitHub ids for a build of Agents from source, put them in the build, and check that sign-in works.
---

# Set up Google, Apple and GitHub sign-in for your own build

The app that Agents ships has its own client ids, so its control plane needs no set-up (see
[Sign in with Google, Apple or GitHub](sign-in-with-google-apple-or-github.md)). When you
build Agents from source, with your own bundle ids and your own Apple team, your build does
not have these ids. Until you make them, **Settings ▸ Control plane ▸ Sign-in** shows Google
and GitHub as not available:

- "This build has no Google client id yet."
- "This build has no GitHub App yet."

Apple shows as available, because the code has it on. But the Sign in with Apple sheet only
works in a build whose App IDs have the capability, so do the Apple steps too.

Do the steps for each provider that you want. You can do one, two or all three.

## Before you start

- An Apple Developer account, with the team that signs your build.
- A Google Cloud project, for Google.
- A GitHub account or organisation that owns the GitHub App, for GitHub.
- The bundle ids of your build. They are `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`:
  `com.alexecollins.agents.store` for the Mac window (the `AgentsStore` target) and
  `com.alexecollins.agents.remote` for the Remote. If you changed them, use your ids in the
  steps below.

All the ids go in one file, `Go/internal/controlplane/signin/config.go`. The control plane
reads them from there and gives each client the id it signs in with. The clients keep no
ids of their own.

## Apple

### Make the ids

1. In the Apple Developer account, open **Certificates, Identifiers & Profiles ▸
   Identifiers**.
2. Open the App ID of the Mac window (`com.alexecollins.agents.store`). Turn on the **Sign
   in with Apple** capability, and save. Do the same for the App ID of the Remote
   (`com.alexecollins.agents.remote`).
3. Make the provisioning profiles of the two targets again, so that they have the new
   capability. Turning on the capability makes the profiles that exist invalid.

You do not need a **Services ID**. A Services ID is for Sign in with Apple on a web page,
and the web page pairs from a code shown on a signed-in client.

### Add the entitlement

The entitlements of the Mac window and of the Remote have this key already (#2507). Make
sure that it is there:

```xml
<key>com.apple.developer.applesignin</key>
<array>
	<string>Default</string>
</array>
```

The files are:

- `App/Agents-Store.entitlements` (the Mac window),
- `Remote/Remote.entitlements` (the Remote),
- `Remote/Remote-AppStore.entitlements` (the Remote's App Store build).

### Put the ids in the build

In `Go/internal/controlplane/signin/config.go`:

- `AppAppleAudiences` lists the bundle ids that a native Sign in with Apple names as its
  audience. Make it your two bundle ids.
- `AppAppleEnabled` is `true` already. Keep it so.

### Why Apple is invite only

Google gives the Workspace domain of an account, so an admin can let a domain join with no
invite. Apple gives no domain. Also, a person can hide their email from Apple sign-in. Then
the control plane gets a relay address, not their real one. So the control plane cannot
match an Apple sign-in to a domain or to an invite's email. A person who signs in with Apple
first joins with an invite code, and then adds Apple as a sign-in. The control plane knows
them by their Apple account, not by the relay address.

## Google

1. In the Google Cloud console, open your project, then **APIs & Services ▸ OAuth consent
   screen**. Set it up, with the scopes `openid`, `email` and `profile`.
2. Open **APIs & Services ▸ Credentials**, select **Create credentials ▸ OAuth client
   ID**, and choose the type **iOS**. Type the Remote's bundle id.
3. Copy the **Client ID**. It ends in `.apps.googleusercontent.com`. This client type has
   no secret, and the clients use PKCE.
4. In `Go/internal/controlplane/signin/config.go`, put the id in `AppGoogleClientIDs`:

   ```go
   AppGoogleClientIDs = []string{"123-abc.apps.googleusercontent.com"}
   ```

The control plane gives each client the first id in the list. It accepts a sign-in made for
any id in the list. Google sends the person back to the app on the client id turned round
(`com.googleusercontent.apps.123-abc`), so you do not register a redirect address.

## GitHub

1. On GitHub, open **Settings ▸ Developer settings ▸ GitHub Apps**, and select **New GitHub
   App** (for an organisation, open the organisation's settings).
2. Type a name and a homepage address.
3. Turn on **Enable Device Flow**.
4. Make sure that **Expire user authorization tokens** is on.
5. Under **Webhook**, turn off **Active**.
6. Under **Permissions**, give only **Organization permissions ▸ Members: Read-only**. Give
   no repository or account permissions.
7. Create the App, and copy its **Client ID**. You do not need a client secret or a private
   key.
8. In `Go/internal/controlplane/signin/config.go`, set `AppGitHubClientID` to the client id.

Use a GitHub App for sign-in only. Do not use the App that connects GitHub to your folders.
Then a token that is passed on has no rights on your repositories.

The **Members** permission lets the control plane check **Allowed GitHub organisations**: it
asks GitHub whether the person is an active member of each organisation. An organisation
must install the App before GitHub tells the App about its members.

## Build again

Build Agents Host, the Mac window and the Remote again. Agents Host's control plane has the
ids from `config.go`, and the window and the Remote have the entitlement.

You can also give the ids to a control plane that you start yourself, with no new build of
it. Set these environment variables for the control plane's process. They replace the ids in
`config.go`:

- `AGENTS_SIGNIN_APPLE_AUDIENCES`: the Apple audiences, with commas between them.
- `AGENTS_SIGNIN_GOOGLE_CLIENT_IDS`: the Google client ids, with commas between them.
- `AGENTS_SIGNIN_GITHUB_CLIENT_ID`: the GitHub App's client id.

The compose files in `deploy/` name each variable that they give to the control plane. They do
not name these. To use them in the cloud, add them under `environment:` of the `control`
service. The Mac window and the Remote must still have the Apple entitlement from your build.

## Turn the providers on

An admin turns each provider on in **Settings ▸ Control plane ▸ Sign-in**, and can allow
Google Workspace domains and GitHub organisations. See [Turn a provider
on](sign-in-with-google-apple-or-github.md#turn-a-provider-on).

## Check that it works

1. In **Settings ▸ Control plane ▸ Sign-in**, make sure that no provider says "This build
   has no … yet". If one does, its id did not get into the control plane: build Agents Host
   again, or check the environment variable.
2. Turn the provider on.
3. On a paired client, open **Settings ▸ Account** on the Mac, or **Settings ▸ Sign-ins** on
   an iPhone or iPad. Select **Add a Sign-in…**, and sign in with the provider. The sign-in
   shows in the list.
4. On a client that is not paired, pair by signing in. See [Pair a new client by
   signing in](sign-in-with-google-apple-or-github.md#pair-a-new-client-by-signing-in).

If a step fails:

- **The Sign in with Apple sheet does not open, or gives an error at once:** the build has
  no `com.apple.developer.applesignin` entitlement, or its provisioning profile does not have
  the capability.
- **Google says that the request is not correct (`invalid_request` or
  `redirect_uri_mismatch`):** the client id is not of the type iOS, or it is wrong in
  `config.go`.
- **GitHub shows no code, or gives an error before the code:** make sure that **Enable
  Device Flow** is on in the App's settings, and that `AppGitHubClientID` is the App's client
  id.
- **"The ID token has expired"**, or another error: see [If sign-in does not
  work](sign-in-with-google-apple-or-github.md#if-sign-in-does-not-work).
