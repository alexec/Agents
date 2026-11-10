---
diataxis: how-to
devices: [mac]
description: Publish Agents for the Mac on GitHub and the iPhone and iPad app on TestFlight by tagging main, and set up the signing secrets the release needs once.
---

# Release Agents

On a Mac, Agents is one app, a Developer ID download from the folder's GitHub releases. It
is not in the Mac App Store. The iPhone and iPad app (the Remote) goes to TestFlight and
the App Store. Pushing a version tag on main publishes a release. The tag starts the
`release` workflow, which:

- builds Agents, with agentsd and agents-control inside it;
- signs it with Developer ID, notarizes it and staples it, as `Agents-<version>.dmg`;
- staples the same app and zips it as `Agents-<version>.zip`, for Macs that cannot mount a
  disk image;
- zips the same signed app again under its old name, `Agents Host.app`, as
  `Agents-Host-<version>.zip`. An install of the earlier Agents Host updates itself from
  this zip. When it runs, agentsd renames it to `Agents.app`, one time (#4225);
- builds the static Linux agentsd (Go) as `agentsd-linux-<arch>-<version>.tar.gz`;
- creates the release, titled **Agents <version>**, with these files and a `SHA256SUMS`.
  Agents on a Mac updates itself from them (#2178): agentsd downloads
  `v<version>/SHA256SUMS` and `v<version>/Agents-<version>.zip`, checks the sum, then the
  app's signature (the same team and identifier), its notarisation and its
  `CFBundleShortVersionString`. Keep these names. Keep the app in `Agents-<version>.zip`
  stapled and named `Agents.app`, and the app in `Agents-Host-<version>.zip` named
  `Agents Host.app`;
- in its `image` job, builds the control plane's image for `linux/amd64` and `linux/arm64`
  and pushes it to `ghcr.io/alexec/agents-control` as `<version>`, `<major>.<minor>` and
  `latest`, with an SBOM and provenance, and signs it with cosign, keyless (#2140). It uses
  the workflow's own token: there is no secret to set. The release is not published unless
  the image pushed;
- in its `testflight` job, archives the Remote, checks the archive with
  `scripts/check-store-archive.sh`, uploads it to TestFlight, and waits until App Store
  Connect has processed it. Nothing goes to App Review here.

The program inside the app keeps the name `Agents Host` (`Contents/MacOS/Agents Host`),
because each login item was registered with that path. Do not rename it.

Beside it, the **app-store** workflow (`app-store.yml`, #3657) waits at the `app-store`
environment's gate for a person to approve the release for App Review. Approve it in Agents
(Needs You ▸ **Deploy**, see [Use GitHub](use-github.md#approve-a-waiting-deploy)) or on
GitHub. Then it waits for the processed build, sets "What's New" to the tag's message and
submits the iOS version for App Review. If you reject it, the release stays on TestFlight
only.

The **Release** workflow (`.agents/workflows/release.md`, the `release` skill) does all of
this when you press **Run now**, and nobody needs to watch it. It chooses the version and
writes the notes. The steps below are the same thing by hand.

## Before you start

You set this up once, as the Apple Developer account's Account Holder.

1. **A Developer ID Application certificate.** In Xcode ▸ Settings ▸ Accounts ▸ Manage
   Certificates, click **+** ▸ **Developer ID Application**. Then right-click it and choose
   **Export Certificate…** to save it as a `.p12` with a password.
2. **The `release` environment.** In Keychain Access, under My Certificates, export
   **Developer ID Application: …** as a `.p12`. Then run
   `scripts/release-secrets.sh path/to/DeveloperID.p12` and delete the `.p12`. The script
   creates `release`, allows only tags matching `v*` to deploy to it, and sets these
   secrets (or set them yourself in Settings ▸ Environments):

   | Secret | Value |
   |---|---|
   | `DEVELOPER_ID_P12` | `base64 -i DeveloperID.p12` |
   | `DEVELOPER_ID_P12_PASSWORD` | the password from step 1 |
   | `ASC_KEY_P8` | the App Store Connect API key's `.p8`, as text |
   | `ASC_KEY_ID`, `ASC_ISSUER_ID` | that key's ID and its issuer ID |

3. **The TestFlight secrets.** Only the Remote is in the App Store (#4229). Export **Apple
   Distribution: …** from Keychain Access as a `.p12` file. Install the three App Store
   profiles: **Agents Remote App Store**, **Agents Remote Notify App Store** and **Agents
   Remote Widget App Store**. Then run `scripts/release-secrets.sh --store Distribution.p12`
   and delete the `.p12` file. It sets:

   | Secret | Value |
   |---|---|
   | `APPLE_DISTRIBUTION_P12`, `APPLE_DISTRIBUTION_P12_PASSWORD` | the Apple Distribution identity and its password |
   | `PROFILE_REMOTE` | `base64` of "Agents Remote App Store" |
   | `PROFILE_REMOTE_NOTIFY` | `base64` of "Agents Remote Notify App Store" |
   | `PROFILE_REMOTE_WIDGET` | `base64` of "Agents Remote Widget App Store" |

   Without these secrets the GitHub release still goes out, and the `testflight` job fails
   at its first step, naming the secrets that are missing.

   Before it archives, the job runs `scripts/check-store-profiles.py` on the three decoded
   profiles (#2781). Each must allow every entitlement in the `.entitlements` file its target
   signs with in Release. The check names a missing entitlement and the secret, never a
   secret's value. `release-secrets.sh --store` runs the same check on the installed profiles
   before it sets anything.

   **A change that adds an entitlement makes the profiles again.** When a pull request adds a
   capability to an App Store target (Sign in with Apple did, #2507), make that target's
   profile again and install it with `scripts/apple-capability.sh <bundle-id> <capability>`
   (#4284; `--dry-run` first, and a real run only after Alex approves it by a form, because it
   changes the Apple Developer account), and update the `release` environment in
   the same change: `scripts/release-secrets.sh --store …`, or
   `base64 -i <profile> | gh secret set PROFILE_… --env release`. Say so in the pull request.
   Setting the secrets is Alex's to approve.

4. **The App Review gate.** Run `scripts/release-secrets.sh --app-store`. It makes the
   `app-store` environment for `v*` tags, with you as its required reviewer
   (`--app-store <login>` names another), and sets `ASC_KEY_P8`, `ASC_KEY_ID` and
   `ASC_ISSUER_ID` in it from `~/.private_keys`. Without a required reviewer the
   **app-store** workflow submits nothing, and says so in a notice: it never goes to App
   Review without a person's approval.

   App Review also needs the App Store listing in App Store Connect (the description, the
   screenshots, the privacy answers and the age rating) before the first submission. The
   script does not write them. Until they are there, App Store Connect refuses the
   submission and the run's log says what is missing.

## Steps

1. Choose the version, for example `0.2.0`: the next minor, because every release is a
   minor (#3212). `.agents/skills/release/scripts/release-plan.py` says which, and lists
   the merged pull requests. The build number is the workflow's run number, so
   it always goes up.
2. Tag main and push the tag. The tag's message becomes the release notes; a tag without
   one gets notes made from the merged pull requests:

   ```sh
   git tag -a --cleanup=verbatim v0.2.0 origin/main -F notes.md
   git push origin v0.2.0
   ```

3. Follow the **release** run in the repository's Actions. The Linux job takes about ten
   minutes. The Mac job takes longer, mostly waiting for Apple's notary.
4. When it finishes, the release is on the Releases page as **Agents 0.2.0**, and
   0.2.0 (the run number) is on TestFlight for iOS.
   `swift scripts/asc-builds.swift 0.2.0 <run number>` says each build's state.
5. The **app-store** run waits for your approval. When you approve it, App Review gets
   0.2.0. `swift scripts/asc-submit.swift 0.2.0` does the same from this Mac.

To make a release again from a tag that is already there (after fixing a secret, say), run
the **release** workflow by hand and give it the tag. It replaces the release's files.

## Build one on this Mac

`scripts/release-host.sh 0.2.0` does what the workflow's Mac job does. It needs the
Developer ID identity in your keychain, and `ASC_KEY_ID`,
`ASC_ISSUER_ID` and `ASC_KEY_PATH` set. It needs the Linux agentsd in `App/Resources/servers`,
from `scripts/build-linux-agentsd.sh`, and Docker running (or Go installed) for the Go
programs Agents carries. It writes `Agents-0.2.0.dmg`, `Agents-0.2.0.zip`,
`Agents-Host-0.2.0.zip`, the Linux tarballs and `SHA256SUMS` into `build/release/`.

`scripts/release-host.sh --dry-run 0.2.0` needs none of that. It signs ad hoc and doesn't
notarize, which proves the build and the packaging. Gatekeeper refuses the result.

`scripts/release-store.sh 0.2.0 <build>` does what the `testflight` job does. It needs the
identities and the profiles in step 3, and the App Store Connect key in `~/.private_keys`.
`--no-upload` stops before the upload. `--dry-run` needs no certificate: it proves the
archives build and pass `check-store-archive.sh`.

The `release-dry-run` workflow runs both dry runs on a runner with an empty build cache
(#2780). It starts on a pull request that changes `scripts/build-cache.sh`,
`scripts/release-*.sh`, `release.yml` or `project.yml`, and the release skill's gate runs it on
the commit it will tag: `gh workflow run release-dry-run.yml -f ref=<sha>`.

## If something goes wrong

- **"is not on main":** the tag points at a commit main doesn't have. Delete the tag
  (`git push origin :refs/tags/v0.2.0`), then tag a commit on main.
- **No "Developer ID Application" identity:** `DEVELOPER_ID_P12` or its password is wrong.
- **The notary refuses it:** the run's log has the submission ID. Run
  `xcrun notarytool log <id> --key … --key-id … --issuer …` to see why.
- **"The release environment has no …":** a TestFlight secret is missing. Run
  `scripts/release-secrets.sh --store …`, then run the **release** workflow again with the tag.
- **"App Store Connect said 409" in the app-store run:** App Review needs something the
  version does not have yet, often a listing field or an answer for the first version. The
  error names it. Add it in App Store Connect, then re-run the failed job.
- **An upload is refused as a duplicate:** that build number is taken for the version. Run
  the workflow again: the new run number is a new build.
- **"PROFILE_… has no …, which ….entitlements asks for":** the profile in that secret was
  made before the entitlement was added. Make it again and install it with
  `scripts/apple-capability.sh` (Alex approves the real run by a form), run
  `scripts/release-secrets.sh --store …`, then run the **release** workflow again with the tag.
