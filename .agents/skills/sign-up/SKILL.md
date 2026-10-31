---
name: sign-up
description: Make a new outside account for Agents (gitlab.com, DigitalOcean, AWS and the like) in a private Chrome, with Alex's rules for terms, cookies, the Privacy.com card, passwords and tokens (#1692). One provider per session. Use when an issue needs an account (`needs-account`), or when Alex asks to sign up to a service.
---

# Sign up to a service

Alex asked for this skill (2026-10-16, 2026-10-19). The 0.7 sign-ups (gitlab.com #1634,
DigitalOcean #865, AWS #1345) wrote it. An account made here is for Agents to test and run
against. It is never Alex's personal account.

## Rules from Alex

- **One provider per session.** Two sign-ups in one session mix up emails, forms and
  questions. To do more than one, start a session for each, each with its own browser
  (below).
- **Browse privately.** Use only the private Chrome that `cdp.mjs` starts: a separate profile,
  incognito, driven over DevTools. Never Safari (Alex's Safari blocks WebDriver, and a touch
  ends the session). Never Alex's own Chrome profile, cookies or sign-ins.
- **Never sign in to Alex's existing accounts** (DigitalOcean, AWS, Microsoft, or any other).
  The new account uses an email address that is not theirs.
- **Accept terms and conditions for Alex** without asking (Alex authorised it, 2026-10-16).
- **Decline cookie banners**: turn off every optional group, then confirm. **Untick every
  marketing box** on the form; some are ticked by default.
- **Pay only with the Privacy.com card.** Never any other card or payment method. Never
  print, log, screenshot or store a card number. Alex types the card in, unless Alex has
  said otherwise for this sign-up.
- **Alex's hands:** every CAPTCHA, email code or link, phone check, and the card. Ask with
  `ask_question` and name who asks ("the <provider> sign-up lane asks: …"). `ask_question` can time
  out after about 60 seconds; then end the turn with the question in your reply instead of
  asking again and again.
- **The private Chrome window is on Alex's screen.** For a code or a CAPTCHA, ask Alex to
  type it straight into that window and reply. Then read the page (`text`, `url`) to see
  that it moved on.
- **The smallest scope** for every token or key, a spend cap or alert where money can be
  spent, and an expiry where the service allows one (a year at most).
- **No secret** in a transcript, the repo, an issue, a message or the tracker. Read secrets
  only inside a script that types or writes them.

## Ask first

In one form, ask Alex for what the forms need: the email address, the name, and, where a
service bills, the phone and the billing address. Keep the phone and the address out of the
tracker, the repo and issues. When other sign-up sessions run alongside, pass the answers to
them with `message_session` so that Alex answers once.

## The private browser

`cdp.mjs` beside this file drives it. Each session sets its own port and profile; the
profiles live in `.agents/signups/` (local only, in `.git/info/exclude`):

```sh
export CDP_PORT=9224 CDP_PROFILE=chrome-profile-digitalocean   # 9223 + chrome-profile is the default
S=.agents/skills/sign-up/cdp.mjs
node $S start                       # launch (no-op when it runs)
node $S open https://example.com/signup
node $S text 3000                   # the page's visible text
node $S eval '<js>'                 # list fields: inputs, ids, names
node $S click '#id'                 # or 'text=Continue'
node $S type '#email' 'name@example.com'
node $S type-secret '#password' 'agents-signup:example.com#name@example.com'
node $S keys '#email' 'name@example.com'   # real keystrokes, for forms that refuse set values
node $S keys '#password' 'kc:agents-signup:example.com#name@example.com'
node $S mclick 'text=Continue'      # a real mouse click
node $S shot /tmp/x.png             # never while a card number shows
node $S stop                        # when done
```

`type-secret` reads the Keychain inside the script, so the password is never printed.
Fields in cross-origin frames (Stripe's card form) are out of reach of `type` and `eval`.
Alex types those.

## Where things live

- **Passwords:** a generic Keychain item `agents-signup:<domain>`, account = the sign-up
  email. Make the password without seeing it:
  `security add-generic-password -s agents-signup:<domain> -a <email> -w "$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)Aa1!"`.
  An older item for the same domain under another account can exist: leave it, and name
  yours with `service#account`.
- **Tokens and keys:** `~/.agents/secrets/<name>`, mode 600. A token shows once: save it with
  a script that finds it in the page (by its prefix, such as `glpat-` or `dop_v1_`) and
  writes the file without printing it. Test it with one API call that prints only a name or
  a status code.
- **Tracker:** `.agents/signups/status.md`, local only: a row per service (account name,
  Keychain item, token path, state) and a log. No secrets.

## Finish

1. Comment on the issue that needed the account: the account name, the cap, the token's
   scope and expiry, and where the password and token are. Never the token itself.
2. Update the tracker row, quit the browser (`node $S stop`) and delete any `/tmp` files.
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
- Alex enters the emailed code. The welcome form (company, group, folder, then dropdowns
  whose choices are `[role=option]`) makes the first group and folder.
- Token: Access tokens, Generate token, Legacy token (by scope) or Fine-grained (by
  folder). Tick only the scopes needed, set an expiry, save the `glpat-` token by script.
- An OAuth application is made under the user's Applications settings once its redirect
  URI is known.

### DigitalOcean ($20/month)

- Tick `#agreeTosRegistration-agreeTosRegistration`, "Sign Up with Email", then `#name`,
  `#email`, `#password`. No CAPTCHA; Alex confirms the email. Cookies: "Decline all".
- Payment: "Add a Payment Method" is a Stripe form in cross-origin frames. It also needs the
  billing address (a Google suggestion fills city, state and ZIP). Tick
  `#paymentTermsConfirmation-confirmed`, then Create. Leave Stripe Link's email and phone
  empty. Stripe shows the full card number: no screenshot while that row is in view.
- Cap: Billing, Spend alerts, Create alert (email at 50/75/90/100%). It does not stop
  droplets.
- Token: API, Generate, Custom Scopes. Ticking "droplet" also ticks `droplet:admin`: expand
  the row and untick it. Generate asks for required read scopes (image, regions, sizes,
  actions, snapshot, vpc): add them. Save the `dop_v1_` token by script.
- Afterwards, check Settings, Notifications for newsletter switches.

### AWS (EC2 only, $20/month)

- AWS's forms check how values arrive: values set by `type` fail with "Sorry, there was an
  error processing your request". Use `keys` and `mclick` for every field and button.
- Cookies: the `awsccc` banner starts with every optional group on in the US. Open Cookie
  Preferences, turn off Performance, Functional and Advertising, save.
- Choose the **Free plan**: it can go to Paid later, Paid cannot go back, and Free cannot
  charge the card. No phone check or CAPTCHA came.
- Card: AWS places a $1 hold. It refused one Privacy.com card ("problem with your payment
  information") and took another. After a refusal the sign-up stops: go to Billing, Payment
  preferences, Add payment method, make the other card the default, then open the sign-up
  URL again and it finishes. If Alex lets the agent type the card, read it into an
  environment variable inside the command (`CARD_NO=$(…) node $S keys '<css>' env:CARD_NO`)
  so the number never reaches the transcript.
- Never make root access keys. Root MFA is Alex's. Make an IAM user (`agents-ec2`) whose
  policy allows only EC2 describe, start, stop and run/terminate on instances with an Agents
  tag; keep a copy of the policy in `.agents/signups/`. Its key goes in
  `~/.agents/secrets/aws-ec2` (credentials-file format, profile `agents-ec2`). The
  access-key description refuses "~".
- The IAM policy editor is Ace: never call `ace.edit()` from outside (it makes a second
  editor the page does not see). Focus `.ace_text-input`, real ⌘A and Backspace, then
  `Input.insertText` of the minified JSON.
- Console tour pop-ups block clicks: press their Next or Done first.
- Turn on a $20/month budget with an email alert (AWS Budgets).
