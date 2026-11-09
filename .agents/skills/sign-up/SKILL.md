---
name: sign-up
description: Make a new outside account for Agents (gitlab.com, DigitalOcean, AWS and the like) with the app's browser tools, with Alex's rules for terms, cookies, the Privacy.com card, passwords and tokens (#1692). One provider per session. Use when an issue needs an account (`needs-account`), or when Alex asks to sign up to a service.
---

# Sign up to a service

Alex asked for this skill (2026-10-16, 2026-10-19). The 0.7 sign-ups (gitlab.com #1634,
DigitalOcean #865, AWS #1345) wrote it. An account made here is for Agents to test and run
against. It is never Alex's personal account.

## Rules from Alex

- **One provider per session.** Two sign-ups in one session mix up emails, forms and
  questions. To do more than one, start a session for each.
- **Ask Alex first, by a form, to make the account** (a new outside account is Alex's to
  decide), and by a form for each charge (#3910). There is no standing approval.
- **Use the app's browser** (`browser_navigate`, `browser_snapshot`, `browser_click`,
  `browser_type`, `browser_fill_form`, `browser_press_key`, …; Alex, 2026-11-06). They take the
  browser lease themselves. Never Safari, and never Alex's own Chrome profile, cookies or
  sign-ins.
- **Never sign in to Alex's existing accounts** (DigitalOcean, AWS root, Microsoft, or any
  other). The new account uses agentstest@alexecollins.com, not Alex's address.
- **Accept terms and conditions for Alex** without asking (Alex authorised it, 2026-10-16).
- **Decline cookie banners**: turn off every optional group, then confirm. **Untick every
  marketing box** on the form; some are ticked by default.
- **Pay only with a Privacy.com card** with a spend limit, after Alex's form for the charge.
  Type it with `fill_secret` (its name in Settings ▸ Secrets, such as `PRIVACY_CARD_2`). Never
  print, log, screenshot or store a card number, and take no snapshot or screenshot while a
  card number shows.
- **Codes:** an email code or link to agentstest@alexecollins.com arrives in `~/.agents/mail`
  as an `.eml` (a Mail rule saves new mail; it misses Junk). Read only the code from it,
  by script. A TOTP code comes from `scripts/totp.sh` (below).
- **What stays with Alex** (only these):
  - **The form** to make the account, and **a form per charge** (#3910).
  - **A CAPTCHA or bot check** (reCAPTCHA, HUMAN's press-and-hold): `hand_to_person` on the
    page (#3907). It is one short step per account; after sign-up, use the site's API, a
    token or a TOTP sign-in, never the sign-up page again.
  - **An SMS code or a phone call** (#3914 is not planned: TOTP only). Ask with
    `ask_question` and name who asks ("the <provider> sign-up lane asks: …"), then type the
    code Alex gives.
  - **A checkout that refuses the agents' browser** (Paddle, #4019): Alex pays from their own
    browser.
  - **A step on Alex's own accounts** (the GitHub App, Apple Developer, Cloudflare, Google
    Cloud, AWS root) until #3911 gives agents scoped tokens.
  - **The Microsoft authenticator** for agentstest, once (#3908).

  Each step you hand to Alex also gets an issue under the autonomy epic (#3905), as AGENTS.md
  says. `ask_question` can time out after about 60 seconds; then end the turn with the
  question in your reply instead of asking again and again.
- **The smallest scope** for every token or key, a spend cap or alert where money can be
  spent, and an expiry where the service allows one (a year at most).
- **No secret** in a transcript, the repo, an issue, a message or the tracker. Type them
  with `fill_secret` or `generate_secret`, and read the others only inside a script that
  types or writes them.

## Is there already an account?

Before anything else, find the person's outside accounts (Settings ▸ You ▸ Accounts, #3967):
`manage_accounts` with `service` (for example `gitlab`). When the service is there, use that
account and do not sign up again. Its `secret` says which secret (or where) the token is,
and its `notes` say where the password is. If `~/.agents/accounts/` still has files (the old
registry, #3909), call `manage_accounts` with action `import` once, then rename the folder to
`~/.agents/accounts.imported`.

## Ask first

In one form, ask Alex to approve the account (and its plan and monthly cost, where it bills)
and for what the forms need beyond the agentstest address: the name and, where a service
bills, the phone and the billing address. Keep the phone and the address out of the tracker,
the repo and issues. When other sign-up sessions run alongside, pass the answers to them with
`message_session` so that Alex answers once.

## The browser

`browser_snapshot` gives the page's fields and their refs; `browser_type` or
`browser_fill_form` fills them, and `browser_click` presses. For a form that refuses set
values (AWS), type with `slowly` (real keystrokes) and press with `browser_click`. Fields in
cross-origin frames (Stripe's card form) are in the snapshot's frame refs; when one is out of
reach, `hand_to_person` it. `browser_take_screenshot` never while a card number shows. Close
the tab with `browser_close` when done.

## Where things live

- **Passwords:** make it with `generate_secret` (#4000) on the password field, named
  `<PROVIDER>_PASSWORD`: it is saved in Settings ▸ Secrets and typed in unseen. Fill a confirm
  field, and later sign-ins, with `fill_secret` and the same name. Give the site's rules as
  `rules` when it states them in words. On a change-password page, set `replace: true`; the
  old value stays as `<NAME>_PREVIOUS`. Older accounts (0.7) keep theirs in the Keychain item
  `agents-signup:<domain>`.
- **Tokens, keys and app passwords a page shows once:** save it with `capture_secret` (#4028)
  on the element that shows it, named `<PROVIDER>_TOKEN` (or `_PASSWORD`), with its prefix as
  `pattern` (`glpat-[A-Za-z0-9_-]{20,}`, `dop_v1_[a-f0-9]{64}`). It is saved in Settings ▸
  Secrets unseen. Never take a snapshot of the page before it. Test it with one API call that
  prints only a name or a status code.
- **Two-factor (#3908):** choose an authenticator app (TOTP) wherever the site offers it;
  SMS or a voice call only when there is no TOTP, because each code then waits for Alex
  (#3906, #3914); never a passkey on Alex's devices, because then every
  sign-in waits for Alex. On the setup page, choose "can't scan" to show the setup key, and
  pipe it from the page into `scripts/totp.sh --save <service>` (it writes
  `~/.agents/secrets/<service>-totp`, mode 600) without printing it. `scripts/totp.sh
  <service>` prints only the current code: read it into a script that types it, never into a
  transcript. Where a site takes only a passkey, use a software passkey on Chrome's virtual
  authenticator (WebAuthn over CDP), its key in `~/.agents/secrets/<service>-passkey.json`:
  `scripts/okta-signin.mjs` makes one with `WebAuthn.addVirtualAuthenticator`, enrols it, and
  saves it with `WebAuthn.getCredentials` for the next run (`okta-integrator-passkey.json`).
- **Accounts:** `manage_accounts` with action `add` (#3967): service, address, plan, monthly
  cost, card (its name in Settings ▸ You ▸ Secrets), secret (its name there, or where it is), the
  2FA method, the issue, the date made, when the token expires, the projects that use it
  (none: all) and notes. Never a secret value, a password or a card number: the control
  plane refuses one that looks like a token, a key or a card number.
  To change an account, give all its fields again: an add that replaces one asks the person
  first (#4001), and a field left out is lost.
- **Tracker:** the account's row in Settings ▸ You ▸ Accounts (`manage_accounts`) and its notes.
  No secrets.

## Finish

1. Comment on the issue that needed the account: the account name, the cap, the token's
   scope and expiry, and where the password and token are. Never the token itself.
2. Add the account with `manage_accounts` (action `add`). Close
   the browser tab (`browser_close`) and delete any `/tmp` files.
3. Tell the session that started you, and end.

## Per provider

What the 0.7 sign-ups found (2026-10-19). Pages change; read the page before you trust these.

### gitlab.com (free)

- Form: `#new_user_first_name`, `_last_name`, `_username`, `_email`, `_password`. The field
  `lastname` is a honeypot: leave it empty. The marketing box
  `#new_user_onboarding_status_email_opt_in` is ticked by default: untick it before
  Continue. No setting undoes it later, only an unsubscribe link.
- Cookies: "Do Not Sell or Share My Personal Information", untick every group, "Confirm My
  Choices". The banner comes back each time the incognito browser starts.
- Read the emailed code from `~/.agents/mail`. The welcome form (company, group, folder, then dropdowns
  whose choices are `[role=option]`) makes the first group and folder.
- Token: Access tokens, Generate token, Legacy token (by scope) or Fine-grained (by
  folder). Tick only the scopes needed, set an expiry, save the `glpat-` token with `capture_secret`.
- An OAuth application is made under the user's Applications settings once its redirect
  URI is known.

### DigitalOcean ($20/month)

- Tick `#agreeTosRegistration-agreeTosRegistration`, "Sign Up with Email", then `#name`,
  `#email`, `#password`. No CAPTCHA; confirm the email from `~/.agents/mail`. Cookies: "Decline all".
- Payment: "Add a Payment Method" is a Stripe form in cross-origin frames. It also needs the
  billing address (a Google suggestion fills city, state and ZIP). Tick
  `#paymentTermsConfirmation-confirmed`, then Create. Leave Stripe Link's email and phone
  empty. Stripe shows the full card number: no screenshot while that row is in view.
- Cap: Billing, Spend alerts, Create alert (email at 50/75/90/100%). It does not stop
  droplets.
- Token: API, Generate, Custom Scopes. Ticking "droplet" also ticks `droplet:admin`: expand
  the row and untick it. Generate asks for required read scopes (image, regions, sizes,
  actions, snapshot, vpc): add them. Save the `dop_v1_` token with `capture_secret`.
- Afterwards, check Settings, Notifications for newsletter switches.

### AWS (EC2 only, $20/month)

- AWS's forms check how values arrive: values set by `type` fail with "Sorry, there was an
  error processing your request". Type every field with `slowly` and press each button with
  `browser_click`.
- Cookies: the `awsccc` banner starts with every optional group on in the US. Open Cookie
  Preferences, turn off Performance, Functional and Advertising, save.
- Choose the **Free plan**: it can go to Paid later, Paid cannot go back, and Free cannot
  charge the card. No phone check or CAPTCHA came.
- Card: AWS places a $1 hold. It refused one Privacy.com card ("problem with your payment
  information") and took another. After a refusal the sign-up stops: go to Billing, Payment
  preferences, Add payment method, make the other card the default, then open the sign-up
  URL again and it finishes. Type the card with `fill_secret`.
- Never make root access keys. Root MFA is Alex's. Make an IAM user (`agents-ec2`) whose
  policy allows only EC2 describe, start, stop and run/terminate on instances with an Agents
  tag; keep a copy of the policy in the account's notes. Its key goes in
  `~/.agents/secrets/aws-ec2` (credentials-file format, profile `agents-ec2`). The
  access-key description refuses "~".
- The IAM policy editor is Ace: never call `ace.edit()` from outside (it makes a second
  editor the page does not see). Click into it, press ⌘A and Backspace with
  `browser_press_key`, then type the minified JSON.
- Console tour pop-ups block clicks: press their Next or Done first.
- Turn on a $20/month budget with an email alert (AWS Budgets).
