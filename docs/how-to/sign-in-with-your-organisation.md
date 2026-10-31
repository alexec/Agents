---
diataxis: how-to
devices: [web, mac, iphone, ipad]
description: Let people sign in with your organisation's Okta, Microsoft Entra ID, Google Workspace or other OIDC provider, claim your domains, and turn on SCIM.
---

# Sign in with your organisation

People can sign in with your organisation's own account in place of Google, Apple or GitHub.
The control plane works with Okta, Microsoft Entra ID, Google Workspace and any other OIDC
provider. You add the provider in **Console ▸ Sign-In** on the web page. The Mac and the
Remote show the providers read only, in **Settings ▸ People**, with **Edit in Console**.

You must be an admin. The control plane must have an HTTPS address and a keeper for its
secrets: without them, it does not save a provider, and says why.

## Add the provider

1. On the web page, open **Console ▸ Sign-In** and select **Add Provider…**.
2. In **Kind**, choose your provider. The kind fills in what it can.
3. Type the **Name on the button**, for example `Acme Okta`. People see "Sign in with Acme Okta".
4. Register an app at your provider (see the steps for your provider below). Use the
   **Redirect URI** that the Console shows after you save. Until then, it is your control
   plane's address followed by `/v1/oidc/callback`.
5. Type the **Issuer**, the **Client ID** and the **Client secret** that the provider gave you.
   The Console never shows the secret again, also to an admin. It shows its fingerprint.
6. In **Who may join**, choose:
   - **Only by invite**: a person must have an invite first. This is the default.
   - **Anyone the provider signs in**: the provider's own app assignment decides.
   - **Only people from SCIM**: your provider adds each person by SCIM.
7. Select **Add Provider**. The control plane reads the issuer's discovery document, and says
   what is missing if the provider cannot do the sign-in.
8. Select **Check** at any time. It reads the discovery document again and counts the
   signing keys.

Use **Move Up** and **Move Down** to set the order of the buttons on the sign-in screen.
**Turn Off** stops new sign-ins with the provider. **Remove…** also removes its domains and
SCIM. A person with no other sign-in keeps their clients until their keys end.

### Okta

1. In the Okta admin console, make an **OIDC – OpenID Connect** app of the type **Web
   Application**.
2. Add the **Redirect URI** as a sign-in redirect URI. Allow the grant types
   **Authorization Code** and **Refresh Token**.
3. The issuer is `https://<your org>.okta.com`, or `https://<your org>.okta.com/oauth2/<server id>`
   when you use a custom authorization server.
4. Keep **Claim that names a person** as `sub`.

### Microsoft Entra ID

1. In the Entra admin centre, open **App registrations** and select **New registration**.
2. Add the **Redirect URI** under the platform **Web**.
3. Under **Certificates & secrets**, make a client secret.
4. The issuer is `https://login.microsoftonline.com/<tenant id>/v2.0`. The Console takes the
   tenant ID from the issuer, so each ID token must come from your tenant.
5. Keep **Claim that names a person** as `oid`. Entra's `sub` is different for each app, and
   its `email` is not checked by Entra.

### Google Workspace

1. In the Google Cloud console, open **APIs & Services ▸ Credentials** and make an **OAuth
   client ID** of the type **Web application**.
2. Add the **Redirect URI** as an authorised redirect URI.
3. The issuer is `https://accounts.google.com`. The kind fills it in.
4. Claim the domain of your Workspace (below), so that only accounts of your Workspace sign in
   with this provider.

## Claim your domains

A claimed domain lets the control plane send people to your provider, and refuse other
providers at the domain.

1. Under the provider, type the domain, for example `acme.com`, and select **Claim Domain**.
2. Add the **TXT record** that the Console shows, with its value, at your DNS host.
3. Select **Check**. When the control plane finds the record, the domain shows **Proved**. It
   checks the record each day, and drops a claim that fails for 7 days.
4. Turn on **Send people here**: when a person types an email at the domain, the sign-in screen
   starts your provider.
5. Turn on **Require this provider** to refuse Google, Apple and GitHub sign-ins at the domain.
   Before it saves, the Console shows each person who signs in at the domain with another
   provider. Their next sign-in, pairing or key renewal must use your provider. The local owner
   is never refused.

## Turn on SCIM

SCIM lets your provider add, change and suspend people and groups. A person that the provider
turns off is suspended within seconds: their clients are cut off and their work stops on their
machines. Nothing is deleted.

1. Under the provider, turn on **Turn On SCIM**.
2. Copy the **Base URL**.
3. Type a name for a token, for example `Okta provisioning`, and select **Make Token**. Copy
   the token at once: it is not shown again. At most two tokens are live at a time, so you can
   replace one with no gap. **Revoke…** ends a token.
4. In **Match a sign-in by**, keep `externalId` unless your provider sends none.
5. At your provider, set the SCIM base URL and the token as a bearer token:
   - **Okta**: in the app's **Provisioning** tab, turn on SCIM, and map `externalId` to
     `user.id`. That is the same value as the `sub` claim.
   - **Microsoft Entra ID**: in the enterprise app's **Provisioning**, set the mode to
     **Automatic**. Change the mapping of `externalId` from `mailNickname` to `objectId`. That
     is the same value as the `oid` claim.

A group that SCIM pushes shows **From Acme Okta** in **Console ▸ People and Groups**. Turn on
**Gives the admin role** to make each person in the group an admin while they are in it. SCIM
never removes the last admin.

When your provider deletes a person, the person is suspended, and **Console ▸ Requests** shows
a **Removal**. Select **Remove…** to see what the person's machines hold that is not pushed,
then remove them.

## See also

- [Sign in with Google, Apple or GitHub](sign-in-with-google-apple-or-github.md)
- [Console](../reference/console.md)
