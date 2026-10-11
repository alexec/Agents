---
diataxis: how-to
devices: [mac]
description: Publish Agents Host on GitHub by tagging main, and set up the signing secrets the release needs once.
---

# Release Agents Host

Agents Host is downloaded from the project's GitHub releases, outside the App Store. That
is the page the Agents window's **Get Agents Host…** opens. Pushing a version tag on main
publishes a release. The tag starts the `release` workflow, which:

- builds Agents Host with agentsd, agents-control and agents-relay inside;
- signs it with Developer ID, notarizes and staples it, as `Agents-Host-<version>.dmg`;
- builds the static Linux agentsd as `agentsd-linux-<arch>-<version>.tar.gz`;
- creates the release with these files and a `SHA256SUMS`.

## Before you start

You set this up once, as the Apple Developer account's Account Holder.

1. **A Developer ID Application certificate.** In Xcode ▸ Settings ▸ Accounts ▸ Manage
   Certificates, click **+** ▸ **Developer ID Application**. Then right-click it and choose
   **Export Certificate…** to save it as a `.p12` with a password.
2. **The relay's profile.** agents-relay reaches CloudKit, which needs a profile outside the
   App Store too. In the developer site's Profiles, make a **Developer ID** profile for the
   App ID `com.alexecollins.agents.bridge`, with the certificate from step 1. Name it exactly
   **Agents Relay Developer ID** and download it.
3. **The `release` environment.** In the repository's Settings ▸ Environments, create
   `release`. Under **Deployment branches and tags**, allow only tags matching `v*`.
   Then add these secrets:

   | Secret | Value |
   |---|---|
   | `DEVELOPER_ID_P12` | `base64 -i DeveloperID.p12` |
   | `DEVELOPER_ID_P12_PASSWORD` | the password from step 1 |
   | `RELAY_PROFILE` | `base64 -i Agents_Relay_Developer_ID.provisionprofile` |
   | `ASC_KEY_P8` | the App Store Connect API key's `.p8`, as text |
   | `ASC_KEY_ID`, `ASC_ISSUER_ID` | that key's ID and its issuer ID |

## Steps

1. Choose the version, for example `0.2.0`. The build number is the workflow's run number,
   so it always goes up.
2. Tag main and push the tag:

   ```sh
   git tag v0.2.0 origin/main
   git push origin v0.2.0
   ```

3. Follow the **release** run in the repository's Actions. The Linux job takes about ten
   minutes. The Mac job takes longer, mostly waiting for Apple's notary.
4. When it finishes, the release is on the Releases page as **Agents Host 0.2.0**, with notes
   made from the merged pull requests.

To make a release again from a tag that is already there (after fixing a secret, say), run
the **release** workflow by hand and give it the tag. It replaces the release's files.

## Build one on this Mac

`scripts/release-host.sh 0.2.0` does what the workflow's Mac job does. It needs the
Developer ID identity in your keychain, the relay's profile installed, and `ASC_KEY_ID`,
`ASC_ISSUER_ID` and `ASC_KEY_PATH` set. It needs the Linux agentsd in `App/Resources/servers`,
from `scripts/build-linux-agentsd.sh`.

`scripts/release-host.sh --dry-run 0.2.0` needs none of that. It signs ad hoc and doesn't
notarize, which proves the build and the packaging. Gatekeeper refuses the result.

## If something goes wrong

- **"is not on main":** the tag points at a commit main doesn't have. Delete the tag
  (`git push origin :refs/tags/v0.2.0`), then tag a commit on main.
- **No "Developer ID Application" identity:** `DEVELOPER_ID_P12` or its password is wrong.
- **The notary refuses it:** the run's log has the submission ID. Run
  `xcrun notarytool log <id> --key … --key-id … --issuer …` to see why.
