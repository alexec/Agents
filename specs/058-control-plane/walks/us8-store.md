# Walk 6: App Store checks (US8, T093)

2026-09-29, from the branch at 86eec71f plus the home-host fix below.

Both archives validate with `altool`. Uploading and submitting them are Alex's call.

## Steps 1–2: the archives

| Archive | Result |
|---|---|
| `AgentsStore`, Release (`xcodebuild archive`, development signing, not exported) | `scripts/check-store-archive.sh`: one Mach-O, the app's own. Its entitlements are T044's four: the sandbox, network client, audio input and user-selected read-only files. |
| The Remote, Release, unsigned (production push needs the distribution profile) | Two Mach-O files, the app and `PlugIns/RemoteNotify.appex/RemoteNotify`, and nothing else. Its Release entitlements are `Remote/Remote-AppStore.entitlements`: production `aps-environment` and iCloud. |
| The developer build of Agents, as a stand-in archive (the negative case) | The script fails it: `Contents/Helpers/agentsd`, the bridge, debug dylibs, and no sandbox. |

### Signing and validation (later the same evening, with Alex's go-ahead)

The team key already on this Mac was used: `~/.private_keys`, App Manager. No second key was
made. Xcode's cloud signing is refused to that role, so the signing was made through the App
Store Connect API instead.

- **Certificates.** Two, each with its private key made on this Mac and imported into the
  login keychain; the temporary copies were deleted.
  - Apple Distribution (`UGRN48USDX`).
  - Mac Installer Distribution (`JD94BVA7AF`, "3rd Party Mac Developer Installer").
  - Both valid to 2027-09-30.
- **The store window's bundle ID** was registered: `com.alexecollins.agents.store`, macOS,
  "Agents Store". The Remote's two were already registered.
- **Profiles.** Three App Store profiles, installed for Xcode: "Agents Store App Store", "Agents
  Remote App Store" and "Agents Remote Notify App Store".
- **`project.yml`.** Release now signs these three targets manually, with Apple Distribution and
  those profiles, so an archive carries the entitlements an upload is checked against.
  - The first export of the unsigned Remote archive had lost them all.
  - Now it has production push and iCloud, the app group and keychain sharing.
- **Exports.** Both archives were made again (both still pass `check-store-archive.sh`) and
  exported for App Store Connect: `Agents.pkg`, signed by the installer certificate, and
  `Agents.ipa`.
- **`altool --validate-app`** first stopped on both with "Unable to find Apple ID for Bundle ID
  … create this app in App Store Connect first", because there were no app records yet.

### App records and validation (with Alex's go-ahead, 21:4x)

- **The records.** Made in App Store Connect's New App form in Chrome, with English (U.K.)
  and Full Access. Both creations said the user access "could not be saved", but that all
  users have access, which is what Full Access means.

  | Record | Platform | Bundle ID | SKU | Apple ID |
  |---|---|---|---|---|
  | Agents for Mac | macOS | `com.alexecollins.agents.store` | `agents-store-mac` | 6817621702 |
  | Agents for iPhone and iPad | iOS | `com.alexecollins.agents.remote` | `agents-remote-ios` | 6817621595 |

- **`Agents.ipa`**: VERIFY SUCCEEDED with no errors.
- **`Agents.pkg`**: first VERIFY FAILED, 90255: "The installer package includes files that
  are only readable by the root user."
  - The archive was made from a shell with umask 077, so `_CodeSignature/CodeResources` was
    `0600`, and the installer package keeps modes.
  - The archive's modes were opened (`chmod -R go+rX`) and it was exported again under umask
    022. Then: VERIFY SUCCEEDED with no errors.
  - `check-store-archive.sh` now fails a Mac archive holding a file not everyone can read.
    It passes both archives here, and it failed a copy with `CodeResources` at `0600`.
- **Nothing was uploaded** that evening.

### Upload, and the notes walked on screen (Alex's "Do T093 for me", 22:0x)

- **Upload.** Both exports went up with `altool --upload-app` as 0.1.0 (1). The Mac build
  processed to VALID; neither was submitted. Publishing is the product's eventual goal, not
  this feature's: nothing further goes to App Store Connect without Alex asking.
- **The demo, restarted.** Its host stopped every ten seconds. `host-entry.sh` passed no
  control flag once it had joined, so the daemon took itself for an ordinary one and left,
  idle. It now passes `--control-network`, and the host stays up across `docker restart`.
- **The notes, on a fresh App Store window** (its container's pairing set aside, then put
  back; launched behind with `open -g -n`, driven by AX):

| Step | Result |
|---|---|
| Where should your agents run? → Connect… (`notes-1-fresh`, `notes-2-code`) | As the notes say. The sheet's words: "It works once, for five minutes", where the demo's codes last 60 days. |
| Paste the operator code, Connect (`notes-5-paired`) | Paired. **Welcome** under **DEMO HOST**, the runtime menu on `demo`, "demo has nothing to adjust." |
| Send "Hello from App Review" (`notes-6-turn`, `notes-7-agent`) | The agent answered "You said: Hello from App Review". But the window raised "Could not reach the helper that runs the agents", and the turn sat under Needs you. |

- **Fixed:** the demo's turn now ends done. The echo cannot report, so the daemon reports it
  (`askForOutcomeIfSilent`). Checked on the demo host with the rebuilt Linux `agentsd`: the
  next turn ended `done` with nothing asked.
- **Not fixed (T093a):** with no host on this Mac, the window keeps a THIS MAC heading with a
  Connecting… row that never goes, and a call after Send goes to `.mac` and fails. The window's
  main client is still this Mac's host.

## Step 3: the demo control plane

`deploy/demo` on this Mac, with the local override: `deploy/demo/local-cert.sh 192.168.0.152`,
then `docker compose -f compose.yaml -f compose.local.yaml up -d --build`.
- The Linux `agents-control` and `agentsd` were built from this branch.
- The copy terminated TLS itself at `https://192.168.0.152:18893`, pinned, because there is no
  public name here. Caddy's public-certificate path is for the real demo.

| Check | Result |
|---|---|
| The codes job | Once the copy had written its settings, it wrote a host code, a device code and an operator code, each good for 60 days. |
| The demo host | It joined as **Demo host** and added the **Welcome** project. `runtimes/list`: every other runtime missing, and `demo` available. |
| The Demo runtime | An agent started on it with "Hello from App Review" answered "You said: Hello from App Review" and finished. The host did not ask it for a report, since it has no tools to give one with. |
| A device, following the notes | The fake iPhone pasted in the device code and paired as a device. `control/status` named Demo host as home. Plain and wrapped, it saw **Welcome** on Demo host. Lending a credential and operator-only calls were refused. |

## Found and fixed

- **A control plane of servers only had no home host.** The home host is where a device's
  plain connection goes. It was set only for a host on the control plane's own machine, so on
  the demo a device connected and then could do nothing: the first test failed with
  `couldNotConnect`, and the Remote would have shown nothing.
  - Now the first host to join is home when there is none, until a host on the control
    plane's own machine joins.
  - Tested in `ControlServiceTests.aServerIsHomeUntilTheControlPlanesOwnMachineJoins`.
- **The Remote could only scan a code**, and its words pointed at the first build's
  Settings ▸ Devices. A reviewer given a code as text needs to paste it, so it now has a Paste
  button, and the words name Agents Host and the control plane.
- **The echo said back the host's whole briefing.** It now says back only the typed prompt.

## Not walked here

- **The review notes on screen, from a fresh App Store window.** The launch was stopped while
  Alex was using the Mac. The same path was taken by the fake device over the same wire. The
  Mac window's Connect… sheet was walked in US1.
- **The Remote on a phone, pasting the code.** Built for the generic simulator; the phone look
  is Alex's.
- **Caddy with a public certificate** needs a public name pointing at the machine.
