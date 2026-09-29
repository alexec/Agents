# Quickstart: walking 058 on scratch (re-plan)

Walks run on scratch roots only. Never use the real root, Alex's paired devices, his keychain
items, or a real bucket that holds anything else. The window is driven with run-app, and the
devbox with test-servers. The Remote is built for the generic simulator, and a fake device
stands in for a phone. Record each walk in `walks/`.

Wire and store details are in [contracts/wire.md](contracts/wire.md) and
[contracts/store.md](contracts/store.md). What a record holds is in
[data-model.md](data-model.md).

## Walk 1: one copy on this Mac (US1, US2, US6; Phase 2 and Phase 6)

**Prerequisites:**
- `Packages/ControlPlane` built;
- the host app's scratch build;
- the window built with `AGENTS_STORE=1` (sandbox on).

1. Start a single copy with a folder store, its own port, a self-signed certificate and no
   Bonjour:
   ```sh
   S=/tmp/cpw; rm -rf $S; mkdir -p $S
   AGENTS_STORE=file://$S/store AGENTS_CONTROL_URL=https://127.0.0.1:8798 \
   AGENTS_CONTROL_KEY_FILE=$S/control-key AGENTS_CONTROL_NO_BONJOUR=1 \
     agents-control serve --port 8798 --self-signed $S/tls &
   agents-control code --host      # prints a host code
   agents-control code --client operator
   ```
2. Start a host on a scratch root, dialling with the host code:
   `agentsd --root $S/host --serve --control '<host code>'`. It shows as online in
   `agents-control hosts`.
3. Launch the scratch window with `AGENTS_CONTROL=<client code>`. Expect it to:
   - pair;
   - show this Mac as a host, with no projects;
   - show frame K's first run when started without the code.
4. Add a project, start a real Claude turn, answer a question, open a file, a diff and the
   terminal, then stop the turn. Screenshot each step.
5. Check nothing leaked out of the sandbox:
   - `ps -o ppid,pid,comm` shows no child of the window;
   - a sandbox violation log (`/usr/bin/log show --predicate 'sender == "Sandbox"'`) shows
     nothing for the window.
6. Reveal a file in Finder and open the shared skills page. Both must go through `mac/reveal`
   and `shared/list` (the host's log shows the calls).
7. Kill the copy for 30 s. The turn carries on (the host log shows it), and the window shows
   the away strip with the URL. Restart the copy: the window catches up within 5 s.

## Walk 2: three copies, a bucket and a load balancer (US3, US6; Phase 3)

**Prerequisites:** Colima running, and `deploy/compose.yaml` bringing up:
- MinIO (bucket `agents-walk`);
- three `agents-control` copies with `AGENTS_STORE=s3://agents-walk/w1`;
- Caddy terminating TLS in front of them with a local certificate, pinned in the codes.

1. `docker compose -f deploy/compose.yaml up -d`, then
   `agents-control --store s3://agents-walk/w1 code --host` (run in any copy's container).
2. Enrol the devbox with the join command from `hosts/startEnroll`. Enrol a scratch local host
   with a second host code.
3. Pair the scratch window as operator, and the fake device (`FakeDeviceLiveTests`, pointed at
   Caddy) as device.
4. Read `leases/` in MinIO and note which copy holds each host. Start a turn on each host from
   the window.
5. Kill the copy that holds the devbox's lease. Expect:
   - the devbox reconnects to another copy;
   - the lease epoch goes up;
   - the window's turn carries on after at most a short offline mark;
   - everything is back within 10 s (SC-003).
6. Kill the copy the window is on. The window reconnects through Caddy to another copy, and
   every host is still listed.
7. Show a client code from one copy, and use it through Caddy until it lands on another. It
   works once, and a second use is `refused: spent`.
8. Forget the fake device from the window. Its socket, on a different copy, closes within 2 s
   (FR-009).
9. Race two grant changes on one client, from two operator clients on different copies. One
   succeeds and the other gets `changedElsewhere`.
10. Stop MinIO. Live turns carry on. Pairing fails with `storeUnavailable`, and `/readyz` goes
    to 503.

## Walk 3: a server joins (US4; Phase 4)

With test-servers and the devbox:
1. Add the devbox by running the shown command on it.
2. Add it a second time over ssh with a scratch key (FR-018a). Afterwards check:
   - no ssh process is left on the control plane's machine;
   - the key is in no file under the store or the copy's folders.
3. Drop the container's network for 60 s, then bring it back. The host reconnects, and its
   agent kept working.
4. Remove the host. It disappears from every client, and its agents are still running on the
   devbox.

## Walk 4: the host app and the move (US2, US7, US9; Phase 5)

1. Seed a scratch root the old way (see the memory file on seeding): agents with history, a
   fake device paired through the old bridge, and the devbox in `hosts.json`.
2. Install the host app's scratch build over it. It runs the host on the existing root, copying
   nothing. Choose **Run the control plane here**, then the move.
3. Expect:
   - every agent is listed with its history;
   - the fake device connects with its old key (`FakeDeviceMoveLiveTests again`) over the new
     wire, after being told the new URL;
   - the devbox is a host or is listed with its command.
4. Start a second host app under another scratch root with a host code. Its projects appear
   under their own heading (US9).

## Walk 5: phone paths (US5; Phase 7)

1. The fake device lists projects on both hosts directly, then through `agents-relay` with the
   relay forced (`AGENTS_FAKE_DEVICE_RELAY=1`). The relayed session shows as relayed in
   Clients (frame N).
2. An agent asks a question. The relay host posts a sealed notice to a scratch CloudKit zone.
   Read it back with the fake device's key.
3. Build the Remote for the generic simulator. Asking Alex to look on the phone is his to
   schedule.

## Walk 6: App Store checks (US8; Phase 8)

1. Archive Agents (Mac) with the App Store configuration. Validate it. List every Mach-O in the
   bundle: only the app's own should be there.
2. Archive the Remote. Validate it with production push.
3. Start the demo control plane container and demo host. Follow the review notes from a fresh
   scratch window.

## Measurements (R14; Phase 9)

Terminal echo and question delivery, median over 200 samples, each compared with the direct
`daemon.sock`, over three paths:
- one copy;
- two copies (client on B, host on A);
- through Caddy.

Record them in `walks/latency.md`.
