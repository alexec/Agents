# Walk 6: App Store checks (US8, T093), as far as it is mine

2026-09-29, from the branch at 86eec71f plus the home-host fix below.

Validating the archives with `altool`, and uploading them, need Alex's App Store Connect
credentials, so steps 1–2 stop at what can be checked here.

## Steps 1–2: the archives

| Archive | Result |
|---|---|
| `AgentsStore`, Release (`xcodebuild archive`, development signing, not exported) | `scripts/check-store-archive.sh`: one Mach-O, the app's own. Its entitlements are T044's four: the sandbox, network client, audio input and user-selected read-only files. |
| The Remote, Release, unsigned (production push needs the distribution profile) | Two Mach-O files, the app and `PlugIns/RemoteNotify.appex/RemoteNotify`, and nothing else. Its Release entitlements are `Remote/Remote-AppStore.entitlements`: production `aps-environment` and iCloud. |
| The developer build of Agents, as a stand-in archive (the negative case) | The script fails it: `Contents/Helpers/agentsd`, the bridge, debug dylibs, and no sandbox. |

Still Alex's: exporting with the distribution profile, `xcrun altool --validate-app` on both,
and any upload.

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
