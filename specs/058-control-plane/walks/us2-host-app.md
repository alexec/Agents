# Walk: US2, Agents Host (T060)

2026-09-29, on the scratch root `/tmp/hw`. The builds were Agents Host (`AgentsHost` scheme)
and the App Store window (`AgentsStore`), from the branch after 3d292fcd. MinIO ran in
Colima as `agents-minio` on `127.0.0.1:19000`, with bucket `agents-walk`.

A scratch Agents Host (`AGENTS_ROOT=/tmp/hw`) puts this Mac's host in `/tmp/hw/host` and the
control plane in `/tmp/hw/control`. It listens on 18791 and labels its launchd jobs
`…scratch-b0c0b6df`. It keeps its key and bucket keys in 0600 files under the root, so
nothing reaches the keychain. `AGENTS_HOST_BONJOUR=1` let it advertise, so K2 could be seen.

Screenshots are in `walks/us2-host-app/`.

## Steps

| Step | Result |
|---|---|
| First start | Frame L's first choice: *Run the control plane here* or *Join one elsewhere*. |
| **Run It Here** | Both jobs were running in **3 s**. `agents-control` listened on `https://alexs-macbook-air.local:18791` and advertised as "Alex's MacBook Air". The host enrolled **as `mac`** with the code Agents Host left in its root, then connected. |
| The jobs | `launchctl list` showed one control job and one daemon job. Quitting and relaunching Agents Host twice left them running and registered nothing twice (US2-4). |
| Frame L (`L-2.png`) | This Mac said "Running your agents · 0 working · 0 projects · Agents Host 0.1.0". The control plane showed its URL, "since …", "1 client · 1 host", and Restart. |
| K2 (`K2.png`) | The App Store window, unpaired, found "Alex's MacBook Air" and showed *Agents Host is running on this Mac*. |
| Pair (`pair-code.png`, `paired.png`) | K2's **Pair** opened `agents-host://pair`, and Agents Host showed an operator code in its sheet. Pasted into the window's sheet and connected, the window was paired as operator and connected. **About 5 s** from Pair to connected, driven by accessibility; a person reading and pasting the code adds their own time (SC-006). |
| In a bucket (`L-bucket.png`) | Endpoint, bucket, prefix `hw`, region and keys were filled in. **Check** said "Works, with safe concurrent writes". |
| Switch to the bucket | **Switch Store…** then confirm. The copy restarted on `s3://agents-walk/hw` in **2 s**, and the host and window both reconnected **without pairing again** (US2-5, US2-6). The running copy had the bucket's keys on descriptor 4 and none in its environment. The pin was unchanged. |
| Switch back to this Mac (`L-back.png`) | 2 s, and everyone reconnected again. The earlier folder store was kept aside as `store-before-<time>`, because a copy refuses a store that already holds records. |
| Afterwards | Both jobs were booted out. No `agentshost` job is left, and no agents-control or agentsd from the walk is running. |

## Found and fixed

- **Two keys in a race.**
  - *Run It Here* started the launcher and at once asked for a host code. Both processes found no key file and each made one.
  - The file kept the second key, so every code was refused with "that key is not this control plane's".
  - The fix: `ControlAgreement.loadOrMake` now creates the file exclusively, so whoever loses reads the winner's key. Agents Host also makes the key before starting the job.
- **K2's Pair opened no code.**
  - A single `Window` scene is never handed a URL by `onOpenURL`, so an app delegate now takes `agents-host://pair`.
  - LaunchServices sends no URL to an app it flags `in-temp-dir`, so this step needs a build outside `/tmp`. The walk used `build/DD-host`.
- **"0 projects" was missing.** `projects/list` wants a params object. Agents Host also keeps one connection to its host instead of opening one every 5 s.
- **"since …" didn't change after a restart or switch.** It is now read again whenever the copy's process changes.
- **Check showed `unavailable("…")`.** It now says "It can't be used: …".

## Not walked, or different from the task

- **Log out and in.** `launchctl print` and `list` showed the jobs instead, as the task allows.
- **A bucket at first run.** The first choice has no store choice, so a bucket is chosen once the control plane runs, then *Switch Store…*. Checking and switching were walked both ways.
- **The ordinary set-up.** `SMAppService` registration, and the key in the real keychain, were not walked. A scratch root uses `launchctl` and files by design. Walking them needs Agents Host at the ordinary root, which is Alex's own move (T105).
- **Frame L's other parts.**
  - The relay row is shown greyed ("Not in this build yet"), since it waits on T096.
  - The move strip isn't shown; it waits on T086.
- **Signing.** Locally the build is signed Apple Development with the team. Developer ID comes with the release archive (T089).
- **Nits seen.** The code in the pairing sheet wraps inside "agents-control". The unpaired store window opens at 1100×720 only after a resize.
