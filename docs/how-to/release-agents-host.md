---
diataxis: how-to
devices: [mac]
description: Publish Agents Host on GitHub and the app on TestFlight by tagging main, and set up the signing secrets the release needs once.
---

# Release Agents Host

Agents Host is downloaded from the folder's GitHub releases, outside the App Store. That
is the page the Agents window's **Get Agents Host…** opens. Pushing a version tag on main
publishes a release. The tag starts the `release` workflow, which:

- builds Agents Host with agentsd, agents-control and agents-relay inside;
- signs it with Developer ID, notarizes and staples it, as `Agents-Host-<version>.dmg`;
- staples the same app and zips it as `Agents-Host-<version>.zip`, for Macs that may not
  mount a disk image;
- builds the static Linux agentsd (Go) as `agentsd-linux-<arch>-<version>.tar.gz`;
- creates the release with these files and a `SHA256SUMS`. Agents Host on a Mac updates
  itself from these (#2178): it downloads `v<version>/SHA256SUMS` and
  `v<version>/Agents-Host-<version>.zip`, checks the sum, then the app's signature (the same
  team and identifier), its notarisation and its `CFBundleShortVersionString`. Keep these
  names, and keep the app in the zip stapled and named `Agents Host.app`;
- in its `image` job, builds the control plane's image for `linux/amd64` and `linux/arm64`
  and pushes it to `ghcr.io/alexec/agents-control` as `<version>`, `<major>.<minor>` and
  `latest`, with an SBOM and provenance, and signs it with cosign, keyless (#2140). It uses
  the workflow's own token: no secret to set. The release is not published unless the image
  pushed;
- in its `testflight` job, archives the Mac window and the Remote (one Universal app),
  checks both archives with `scripts/check-store-archive.sh`, uploads them to TestFlight
  and waits until App Store Connect has processed both. Nothing goes to App Review.

The **Release** workflow (`.agents/workflows/release.md`, the `release` skill) does all of
this when you press **Run now**, and nobody needs to watch it. It has the high and medium
findings fixed first, chooses the version and writes the notes. The steps below are the
same thing by hand.

## Before you start

You set this up once, as the Apple Developer account's Account Holder.

1. **A Developer ID Application certificate.** In Xcode ▸ Settings ▸ Accounts ▸ Manage
   Certificates, click **+** ▸ **Developer ID Application**. Then right-click it and choose
   **Export Certificate…** to save it as a `.p12` with a password.
2. **The relay's profile.** agents-relay reaches CloudKit, which needs a profile outside the
   App Store too. In the developer site's Profiles, make a **Developer ID** profile for the
   App ID `com.alexecollins.agents.bridge`, with the certificate from step 1. Name it exactly
   **Agents Relay Developer ID** and download it.
3. **The `release` environment.** In Keychain Access, under My Certificates, export
   **Developer ID Application: …** as a `.p12`. Then run
   `scripts/release-secrets.sh path/to/DeveloperID.p12` and delete the `.p12`. The script
   creates `release`, allows only tags matching `v*` to deploy to it, and sets these
   secrets (or set them yourself in Settings ▸ Environments):

   | Secret | Value |
   |---|---|
   | `DEVELOPER_ID_P12` | `base64 -i DeveloperID.p12` |
   | `DEVELOPER_ID_P12_PASSWORD` | the password from step 1 |
   | `RELAY_PROFILE` | `base64 -i Agents_Relay_Developer_ID.provisionprofile` |
   | `ASC_KEY_P8` | the App Store Connect API key's `.p8`, as text |
   | `ASC_KEY_ID`, `ASC_ISSUER_ID` | that key's ID and its issuer ID |

4. **The TestFlight secrets.** Export **Apple Distribution: …** and **3rd Party Mac
   Developer Installer: …** from Keychain Access as two `.p12` files. Install the four App
   Store profiles: **Agents Universal Mac App Store**, **Agents Remote App Store**,
   **Agents Remote Notify App Store** and **Agents Remote Widget App Store**. Then run
   `scripts/release-secrets.sh --store Distribution.p12 Installer.p12` and delete both
   `.p12` files. It sets:

   | Secret | Value |
   |---|---|
   | `APPLE_DISTRIBUTION_P12`, `APPLE_DISTRIBUTION_P12_PASSWORD` | the Apple Distribution identity and its password |
   | `MAC_INSTALLER_P12`, `MAC_INSTALLER_P12_PASSWORD` | the 3rd Party Mac Developer Installer identity and its password |
   | `PROFILE_UNIVERSAL_MAC` | `base64` of "Agents Universal Mac App Store" |
   | `PROFILE_REMOTE` | `base64` of "Agents Remote App Store" |
   | `PROFILE_REMOTE_NOTIFY` | `base64` of "Agents Remote Notify App Store" |
   | `PROFILE_REMOTE_WIDGET` | `base64` of "Agents Remote Widget App Store" |

   Without them the GitHub release still goes out, and the `testflight` job fails at its
   first step, naming the secrets that are missing.

   Before it archives, the job runs `scripts/check-store-profiles.py` on the four decoded
   profiles (#2781). Each must allow every entitlement in the `.entitlements` file its target
   signs with in Release. The check names a missing entitlement and the secret, never a
   secret's value. `release-secrets.sh --store` runs the same check on the installed profiles
   before it sets anything.

   **A change that adds an entitlement makes the profiles again.** When a pull request adds a
   capability to an App Store target (Sign in with Apple did, #2507), make that target's
   profile again in the developer site, install it, and update the `release` environment in
   the same change: `scripts/release-secrets.sh --store …`, or
   `base64 -i <profile> | gh secret set PROFILE_… --env release`. Say so in the pull request.
   Setting the secrets is Alex's to approve.

## Steps

1. Choose the version, for example `0.2.0`: minor when an enhancement merged since the
   last tag, otherwise patch. `.agents/skills/release/scripts/release-plan.py` says which,
   and lists the merged pull requests. The build number is the workflow's run number, so
   it always goes up.
2. Tag main and push the tag. The tag's message becomes the release notes; a tag without
   one gets notes made from the merged pull requests:

   ```sh
   git tag -a --cleanup=verbatim v0.2.0 origin/main -F notes.md
   git push origin v0.2.0
   ```

3. Follow the **release** run in the repository's Actions. The Linux job takes about ten
   minutes. The Mac job takes longer, mostly waiting for Apple's notary.
4. When it finishes, the release is on the Releases page as **Agents Host 0.2.0**, and
   0.2.0 (the run number) is on TestFlight for iOS and macOS.
   `swift scripts/asc-builds.swift 0.2.0 <run number>` says each build's state.

To make a release again from a tag that is already there (after fixing a secret, say), run
the **release** workflow by hand and give it the tag. It replaces the release's files.

## Build one on this Mac

`scripts/release-host.sh 0.2.0` does what the workflow's Mac job does. It needs the
Developer ID identity in your keychain, the relay's profile installed, and `ASC_KEY_ID`,
`ASC_ISSUER_ID` and `ASC_KEY_PATH` set. It needs the Linux agentsd in `App/Resources/servers`,
from `scripts/build-linux-agentsd.sh`, and Docker running (or Go installed) for the Go
programs Agents Host carries.

`scripts/release-host.sh --dry-run 0.2.0` needs none of that. It signs ad hoc and doesn't
notarize, which proves the build and the packaging. Gatekeeper refuses the result.

`scripts/release-store.sh 0.2.0 <build>` does what the `testflight` job does. It needs the
two identities and the four profiles, and the App Store Connect key in `~/.private_keys`.
`--no-upload` stops before the upload. `--dry-run` needs no certificate: it proves both
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
- **An upload is refused as a duplicate:** that build number is taken for the version. Run
  the workflow again: the new run number is a new build.
- **"PROFILE_… has no …, which ….entitlements asks for":** the profile in that secret was
  made before the entitlement was added. Make it again in the developer site, install it, run
  `scripts/release-secrets.sh --store …`, then run the **release** workflow again with the tag.
