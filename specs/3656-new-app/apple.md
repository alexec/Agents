---
description: The Apple steps of a new iPhone app (#3709, epic #3656) - the hand_to_person cards, the team API key as three CI secrets, the team id as a variable, and the bundle id from the starter's setup job - as the start-a-new-app skill (#3712) follows them.
---

# A new app's Apple account (#3709)

Issue #3709, a child of epic #3656 (`spec.md`, "What each account needs"). The steps
below are for an agent. The `start-a-new-app` skill (#3712) takes them as its Apple part.
They use only tools that the app has now: the browser tools, `hand_to_person` (#3529),
`ask_secret` (#3548), `ask_question`, `set_ci_secret` and `set_ci_variable` (#3706), and
the GitHub server's `run.completed` event and `failed_log` tool.

## What is there before these steps

- `make_app_repository` made the repository from the `iphone-app` starter (#3708), with
  `BUNDLE_ID` (for example `com.someone.tidelog`) and `APP_NAME` filled in. Its
  `setup.yml` registers the bundle id; `release.yml` and `app-store.yml` sign and ship.
- The `testflight` and `app-store` environments have the person as their required
  reviewer (`set_environment_gate`).

## The steps

Do each step only when it is not done yet. When the person answers **Can't do it**, stop,
say what is left, and end. When the flow starts again, it goes on from the first step
that is not done.

1. **Look at what is there.** In the repository's **Settings ▸ Secrets and variables ▸
   Actions** (`https://github.com/<owner>/<repo>/settings/secrets/actions`, with
   `browser_snapshot`), or with `gh secret list` and `gh variable list` where `gh` is
   signed in: the names `ASC_KEY_P8`, `ASC_KEY_ID`, `ASC_ISSUER_ID` and `APPLE_TEAM_ID`
   that are there already skip steps 3 to 6. A successful `setup.yml` run skips step 7.
2. **Enrol in the Apple Developer Program.** Go to `https://developer.apple.com/account`
   with `browser_navigate`. When the page asks for a sign-in, or offers to enrol (there is
   no **Membership details**), call `hand_to_person`:
   - step: `Sign in with your Apple Account, enrol in the Apple Developer Program, and pay`;
   - reason: `Only a member of the Apple Developer Program can put an app on TestFlight and the App Store. Only you can enrol and pay.`

   The person enrols and pays. The agent never types a card or an Apple password. Apple
   can take up to two days to approve a new member: when the person answers **Can't do
   it** for that reason, stop and say that the flow goes on from here after Apple's email.
3. **The team id.** On `https://developer.apple.com/account`, **Membership details** has
   the **Team ID**: ten letters and digits, such as `A1B2C3D4E5`. Read it with
   `browser_snapshot`. When the page does not show it, `ask_question` with free text:
   `Paste the Team ID from Membership details on developer.apple.com/account.` Check it
   against `^[A-Z0-9]{10}$`, then call `set_ci_variable` with `APPLE_TEAM_ID`. It is not a
   secret: it is in every app that the team signs.
4. **Make the team API key.** Go to
   `https://appstoreconnect.apple.com/access/integrations/api` and call `hand_to_person`:
   - step: `If asked, click Request Access and accept the terms. Then click + (Generate API Key), name it <app> CI, choose the role Admin, click Generate, and download the key`;
   - reason: `GitHub signs and uploads the app with this key, so there is no certificate or profile to keep. Xcode's cloud-managed signing refuses a key with a smaller role than Admin. Apple lets you download it only once.`

   Only the Account Holder can request API access, once per team. The key's role cannot
   be changed after it is made: a key with another role is revoked and made again.
5. **Ask for the key.** Call `ask_secret` three times, each for this session only, with the
   `url` of the same page:
   - `ASC_KEY_P8`, reason: `The text of the AuthKey_….p8 file you downloaded: open it in TextEdit, select all, copy and paste it here.`
   - `ASC_KEY_ID`, reason: `The Key ID beside the key's name.`
   - `ASC_ISSUER_ID`, reason: `The Issuer ID above the list of keys.`

   The form's field is one line, so the `.p8` text loses its line breaks: that is
   expected. The starter's `scripts/asc-key.sh` puts them back in each workflow. Never read
   the downloaded file into the chat.
6. **Set the secrets.** Call `set_ci_secret` three times, on the new repository: secret
   `ASC_KEY_P8`, `ASC_KEY_ID` and `ASC_ISSUER_ID`, each from the session secret of the same
   name. The host seals each one; the agent never sees a value. Then say to the person
   that they can delete the downloaded `.p8` file: the repository has it.
7. **Register the bundle id.** Run the starter's `setup` workflow: `gh workflow run
   setup.yml --repo <owner>/<repo>` where `gh` is signed in; else go to
   `https://github.com/<owner>/<repo>/actions/workflows/setup.yml`, click **Run
   workflow**, then the green **Run workflow** in its menu. When neither works, call
   `hand_to_person` with step `Click Run workflow, then Run workflow again` and reason
   `This job registers the app's bundle id with Apple, with the key you made.` Wait with
   `wait_for_event` on `run.completed`, `where: {"repo": "<owner>/<repo>", "workflow":
   "setup.yml"}`. When its conclusion is not `success`, read `failed_log`:
   - `said 401`: a value is wrong. Ask again for `ASC_KEY_ID` and `ASC_ISSUER_ID` (step 5)
     and set them again.
   - `said 403`: the key's role is too small. Go back to step 4 for a new Admin key.
   - `is not the text of a .p8 file`: ask again for `ASC_KEY_P8`.

   The job does nothing when the bundle id is there already, so it is safe to run again.
8. **Make the app's record.** App Store Connect's API has no call that makes an app, so
   this is a card. Go to `https://appstoreconnect.apple.com/apps` and call `hand_to_person`:
   - step: `Click + then New App. Choose iOS, name it <app name>, choose the bundle id <bundle id>, type <repo> as the SKU, and click Create`;
   - reason: `TestFlight and the App Store need the app's record, and only a person can make it.`

   When the name is taken in the App Store, the person picks another: the name in the
   record is what the store shows, and the app's own name can stay.

The Apple part is then done: a tag `v0.1.0` uploads the first build (`release.yml`).

## What reaches the machine

The three values of the key, for this session only, in
`~/.agents-secrets/sessions/<agent>.json`, deleted when the session is archived (#3548);
`set_ci_secret` reads them there and puts them sealed into the repository. The agent
never sees them. The downloaded `.p8` file is in the Agent Browser's downloads until the
person deletes it. The team id is not secret. The person signs in to Apple in the Agent
Browser, as for every `hand_to_person` card; Agents' daemon and the control plane never
read that sign-in.

## Decisions

- **Decided: the key's role is Admin,** because that is the smallest role that
  cloud-managed signing takes. A key with the Developer or App Manager role signs in, then
  `xcodebuild -allowProvisioningUpdates` fails with "Cloud signing permission error"
  ([rxliuli, 2025](https://rxliuli.com/blog/two-pitfalls-of-safari-cloud-signing-in-github-actions/)).
  The other choice, App Manager with a `.p12` and profiles, is the nine secrets that the
  spec takes out. Alex can overrule.
- **Decided: the workflows rebuild the `.p8` text** (`scripts/asc-key.sh`), because the
  secret form has one line, and a pasted key with no line breaks does not parse. The other
  choice, a new tool that reads the downloaded file, would read a file the agent did not
  make. Alex can overrule.
- **Decided: `APPLE_TEAM_ID` is a variable, read from the membership page,** because it is
  not a secret, and App Store Connect's API does not give it. Alex can overrule.
- **Decided: no new tool and no new screen.** Because `hand_to_person`, `ask_secret`, the
  CI tools, the browser tools and the `run.completed` event do each step. Alex can
  overrule.
