# __APP_NAME__

An iPhone app in SwiftUI. Each version tag (`v1.2.0`) uploads a build to TestFlight, and,
when a person approves it, submits it for App Review. Crashes go to Sentry.

## Build it on your Mac

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
2. Run `xcodegen generate`, then open `App.xcodeproj`.

## Set it up once

1. In GitHub, make the environments `testflight` and `app-store` (**Settings ▸
   Environments**), each with **Required reviewers**. Nothing ships before a reviewer
   approves it.
2. In App Store Connect, make a team API key (**Users and Access ▸ Integrations ▸ Team
   Keys**) with the role **Admin**, and download it. Cloud-managed signing refuses a key with
   a smaller role. Put it in the repository's secrets:
   - `ASC_KEY_P8`: the text of the `.p8` file. Its line breaks can go: the workflows put
     them back (`scripts/asc-key.sh`).
   - `ASC_KEY_ID`: the key's ID.
   - `ASC_ISSUER_ID`: the issuer ID, above the list of keys.
3. Put your team ID (**Membership details** on developer.apple.com) in the repository
   variable `APPLE_TEAM_ID`.
4. Run the **setup** workflow (**Actions ▸ setup ▸ Run workflow**). It registers the bundle
   id `__BUNDLE_ID__`.
5. In App Store Connect, make the app's record (**Apps ▸ + ▸ New App**) with that bundle
   id.
6. For Sentry, put the project's DSN in the repository variable `SENTRY_DSN`. With no DSN,
   the app sends nothing. For crashes with names and lines, also put the project's slug in
   the variable `SENTRY_PROJECT`, and an organization token (Sentry's **Settings ▸
   Organization Tokens**) in the secret `SENTRY_AUTH_TOKEN`: `release.yml` then uploads the
   debug symbols.

Signing is Xcode's cloud-managed signing: Apple makes the certificate and the profile from
the key, so there is no certificate or profile to keep.

## Ship a version

```sh
git tag -a v0.1.0 -m "What is new in this version"
git push origin v0.1.0
```

- `release.yml` waits for a reviewer of `testflight`, then uploads build
  `<run number>` of version `0.1.0` to TestFlight.
- `app-store.yml` waits for a reviewer of `app-store`, then waits for the build to be
  processed and submits it for App Review. The tag's message is "What's New".

Each workflow says what it shipped with a notice, such as
`::notice title=deploy::testflight:__BUNDLE_ID__/42`. Agents reads it and shows the build
beside the release that it came from.
