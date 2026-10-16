# Spike #1126: the control plane in Go

Throwaway code. It is not merged into the product. Part of #1126; the host half is #1125.

## Stages

One line for each stage, written when the stage was committed.

1. **Store: done.** `internal/store` has three stores: memory, a folder, and a bucket through `gocloud.dev/blob` + `s3blob`. The cases from `StoreConformanceTests.swift` are ported, plus a race of 20 If-Match writes. All pass on memory, the folder and MinIO (`cgr.dev/chainguard/minio`). The folder store writes the same paths and the same SHA-256 tags as the Swift `FolderStore`, so each can read the other's folder.

2. **Auth and join: done.** `internal/auth` does the hello/auth/ok exchange (both sides), the v2 codes, and the client, host, code and copy key derivations. It passes Swift's `Web/test/vectors.json`. `internal/records` writes the same JSON as the Swift records (ISO dates with milliseconds, UUIDs in upper case, tombstones, `rev`), and the ported `revAndTombstones` case passes. `internal/service` has the TLS WebSocket server, codes that are used once (with #212 replays), pairing, enrolment, and a `mac` home host. Tested live with **today's Swift `agentsd` and the Mac window, with no change to either**: the host enrolled as `mac` and connected, the window paired with `AGENTS_CONTROL` and opened two channels, and a Claude turn ran end to end (its permission card was answered through the control plane). `cmd/agents-control` has the same `serve --home` / `code` command line as the Swift tool, so `run.sh` can put it in place of the Swift one. (The router and the web listener are in this commit too, because the service needs them to build. Stages 3 and 5 test them.)
3. **Router: done for one copy.** `internal/service/router.go` ports `ControlRouter`: a channel for each client on each host, requests passed down as their own bytes, `fanOut` frames, `hostOffline` for calls in flight when a host goes, `noSuchHost`, today's Remote on the bare wire to the home host, 4403 for a forgotten client, relay hosts with no client channels, and sign-in tunnels between hosts. Live, all at once on one Go control plane: **the Mac window, today's Swift `agentsd` as `mac`, the #1125 Go `agentsd` on this Mac, and the #1125 Go `agentsd` on the agents-devbox (Linux)**, plus `agentsctl` as a second client. A Claude turn ran on each host through the router. The Linux Go host borrowed this Mac's Claude sign-in through the router's tunnel (the Swift `mac` lent it with `relay/grant`). Earlier, with two Swift hosts: a host that was stopped was shown offline and its calls answered `-32090`, and it rejoined with its membership and no code. `hosts/remove` took two hosts away, after which calls to them are answered `-32091`. In-process tests cover the rest, tunnels included. Not ported: copies linked over one store, leases, handover, kept requests, the "last heard" copies of a host's lists (#962), and presence folding for notices.
4. **KMS: done with the local keeper; Google Cloud KMS is written but not run.** `internal/kms` uses an envelope. A fresh data key encrypts the control plane's private key with AES-256-GCM. A `gocloud.dev/secrets` keeper wraps the data key. The envelope is kept in the store at `v1/keys/control.sealed`. With `AGENTS_CONTROL_KMS` set, a copy needs no key file: any copy that has the bucket and the use of the KMS key gets the control key, and the bucket alone gives nothing. When copies start together on an empty store, they settle on one key (tested with 10). Live on MinIO: no `control-key` was on disk, and the bucket held only the sealed envelope. A restart with another keeper key refused to start ("localsecrets: Decrypt failed"). A restart with the right key served again, and today's Swift host reconnected by itself, so the key was the same. `agents-control code` works the same way. `gcpkms://projects/…/cryptoKeys/…` is linked in and parses; opening it needs Alex's account (#61).
5. **The web page: done, except for a real browser.** `internal/service/web.go` ports `LoopbackListener`: `Web/dist` served from its MANIFEST with hashes checked, 127.0.0.1 and ::1 on one port, the same headers (CSP and the rest), 421 for another Host, 308 from the address to `localhost`, 405 for anything but GET, and the socket at `/v1/connect` only from the page's own Origin (403 otherwise). A browser's key and code work only here, and the exchange is bound to `http://localhost:<port>`. Live, with curl and `cmd/webcheck`, which does what the page does: a `--browser` code paired a browser client; `control/status`, `daemon/ping` and `agents/list` reached `mac` through it; and a window's code was refused at this door with the Swift words. **Not seen in a real browser:** the screen was locked and Alex's Safari was open, which is when safaridriver times out. The page's crypto is Swift's (`Web/test/vectors.json`), and stage 2 tests the Go side against those vectors. Left out: the MCP Apps sandbox proxy's own CSP from `?csp=` (#187), which is served with a fixed policy here.
6. **Add a Server over ssh: done without tunnels** (beyond the issue). `GET /v1/install.sh` serves the Swift `HostInstallScript`, byte for byte (taken from `agents-control install-script`), and `/v1/servers/<file>` serves the Linux hosts from `AGENTS_CONTROL_SERVERS` (`gohosts.sh build` puts the #1125 Go host there). A host code's `command` is the same line the Swift one makes. `hosts/install` checks the host key as #610 does: the person's known_hosts with `StrictHostKeyChecking=yes`, a key it does not have answered with `needsTrust` and its fingerprint, and that fingerprint installs. The key goes into the install's own folder, never the person's known_hosts. Then the server runs the install script itself, fed on ssh's standard input so the code is on no command line on the Mac. Swift copies the binary over ssh instead, and that needs no route from the server to the control plane, but a host needs that route anyway. Live against the devbox: `agents@127.0.0.1:2222` installed and joined in 1.4 s. A config whose known_hosts was empty got `needsTrust` with the box's real fingerprint, that fingerprint installed, a wrong one was asked again, and no ssh was left running. Not ported: tunnels through a bastion (#435), `hosts/detect`, `hosts/update`, `hosts/checkAgain`, and the MCP servers beside the host (the script says the control plane offers no `ci-watcher`).

## Libraries and what they missed

- **gocloud.dev/blob v0.46** (v0.47 needs Go 1.26; the toolchain image is 1.25):
  - It has `IfNotExist` (If-None-Match: \*) for S3 and for files.
  - It has **no If-Match**. I worked round this: `BeforeWrite` → `As(*transfermanager.UploadObjectInput)` → set `IfMatch`. This works only on the S3 driver. On any other driver the write is refused, and the start-up probe refuses that store.
  - A write **does not return the entity tag**. The store uses the quoted MD5 of the bytes, which is the tag that S3 and MinIO give a single-part upload. With SSE-KMS on AWS the tag is not the MD5, so conditional writes against such a bucket would always conflict. This is a known gap.
  - It maps **409 ConditionalRequestConflict** (two writes that race on AWS) to `Unknown`. The store reads the smithy error code through `errors.As`.
  - `fileblob` has no If-Match, so the folder store is written by hand (flock, temporary file, fsync, rename, folder fsync), as in Swift.
  - `s3blob.Delete` does a HEAD before each DELETE: one more request for each delete.
- **gocloud.dev/secrets** (`localsecrets`, `gcpkms`): did what I needed. It wraps and unwraps bytes, nothing more. The envelope (data key, AES-GCM, where to keep it) is 150 lines of my own. `gcpkms` pulls in the Google Cloud client libraries: the binary went from 30.6 MB to 35.7 MB (debug symbols in; the Swift `agents-control` in a Debug build is 97 MB).
- **Colima** (not a library): on 2026-10-16 it did not forward a new container's port to the Mac. The devbox's older port still worked. `minio.sh` reaches MinIO through an ssh tunnel over the devbox's sshd. Restarting Colima would probably fix it, but that is Alex's to do.

## Numbers

| | Go (this spike) | Swift (today) |
|---|---|---|
| Lines, not counting tests | 4,050 for the control plane (`internal/`, `cmd/agents-control`), plus 430 for tools (`webcheck`, scripts not counted) | About 6,800 for the same parts: `ControlStore`, `ControlAuth`, `ControlCode`, `ControlWire`, `ControlRouter`, `ControlRecords`, `ControlMethods`, `Grant`, `ControlAgreement`, `ControlService`, `LoopbackListener`, `S3Store`, `agents-control`. The whole of `Packages/ControlPlane` is 8,541, and 5,900 of those are parts not ported (providers 2,862, ssh hosts 1,365, channels 785, copies 457, handover 410). |
| Lines of tests | 797 | — |
| Binary | 24 MB for Linux arm64, stripped (35.7 MB for macOS with symbols) | The `agents-control` image is 107 MB; the Debug macOS helper is 97 MB |
| Build | 32 s with an empty build cache (modules cached), 20 s warm, both in the `golang:1.25` container | Minutes. The #1125 lane timed the Swift Linux `agentsd` at 336 s for one architecture |
| Memory, idle | 26 MB, with three hosts and two clients | 30 MB, with one host and no window |

## What the clients would need

Nothing so far. Today's Mac window, Swift `agentsd`, the #1125 Go `agentsd`, and the web page's wire (as `webcheck` speaks it) all worked unchanged. The window has not been seen on screen (the Mac was locked), so how it *looks* with a Go control plane behind it is the first thing to check. Methods the Go control plane answers with "cannot do that" are listed under "Known broken" below. The window shows those errors where it shows them for a control plane of several copies.

## For Alex's test (evening of 2026-10-17)

Everything runs on scratch roots (`/tmp/run-<slug>`), MinIO in a container of its own, and the agents-devbox container. Nothing touches the live control plane or Agents Host. Work from the worktree:

```sh
cd ~/Agents/.agents/worktrees/do-spike-github-issue-2/controlplane-go
```

**Before you start.** The scratch build of Agents Host and the window is already in this worktree's `build/DD`, and the Go binaries are in `out/` (not checked in). To make the binaries again, using the "build" lease:

```sh
GOOS=darwin ./go.sh build -o out/darwin/agents-control ./cmd/agents-control
GOOS=darwin ./go.sh build -o out/darwin/webcheck ./cmd/webcheck
./gohosts.sh build      # the #1125 Go agentsd and agentsctl, from a copy of that worktree
```

**A. The Go control plane, today's Swift host and the window** (stages 2 and 3):

```sh
./run.sh up cpgo --lan          # prints ROOT, CONTROL_URL, WEB_URL, the pids
tail -f /tmp/run-cpgo/control/control.log
```

In the scratch window (its title says `run-cpgo`). I have not seen it on screen, so these are the things to look at, not steps I have walked:
1. The control plane's page in Settings shows "run-cpgo (Go)", version 0.1, and this Mac's host connected.
2. Add a project on this Mac's host, start a Claude session in it, and allow its permission card.
3. Pair another client from the window (its code comes from the Go control plane), then forget it. Its sockets close with 4403.
4. Add a Server ▸ Over ssh: `agents@127.0.0.1:2222` (the devbox; `./gohosts.sh build` first, so the control plane has a Linux host to give it). It joins as the #1125 Go host in `~/.agents-server`. Remove it afterwards and run `ssh -p 2222 agents@127.0.0.1 'kill $(cat ~/.agents-server/root/daemon.lock); rm -rf ~/.agents-server'`. Add a Server by command works too: run the line it shows on the box.

**B. The Go hosts at the same time** (stage 3):

```sh
./gohosts.sh up cpgo     # the #1125 Go agentsd on this Mac (/tmp/run-cpgo-g) and on the devbox (~/.agents-cpgo)
```

The window now lists three hosts: this Mac (Swift), "This Mac (Go host)" and "devbox (Go host)". Start a Claude session on the devbox host, in `/home/agents/src/cpgo`. The window asks to lend this Mac's Claude sign-in: say yes. The lend goes through the Go router's tunnel.

**C. The web page** (stage 5). Open `WEB_URL` (printed by `run.sh`) in Safari, then pair with `./run.sh code cpgo --client --browser`. Check the hosts, a chat, and a turn. Without a browser:

```sh
./out/darwin/webcheck <web port> "$(./run.sh code cpgo --client --browser)"
```

**D. A bucket and a KMS** (stages 1 and 4):

```sh
./minio.sh up                          # MinIO on 127.0.0.1:19100, through the devbox's ssh
./run.sh up cpgok --s3 --kms --no-window
ls /tmp/run-cpgok/control              # no control-key: it is sealed in the bucket
curl -s --aws-sigv4 aws:amz:us-east-1:s3 --user spike:spike-secret-key \
  "http://127.0.0.1:19100/cpgo?list-type=2&prefix=cpgok/" | grep -o '<Key>[^<]*</Key>'
```

**E. Without the screen.** The same calls the window makes, with `agentsctl` from #1125:

```sh
C=~/Library/Caches/Agents-build/cpgo-agentsd-go/out/darwin/agentsctl; export AGENTSCTL=/tmp/run-cpgo/ctl.json
$C pair "$(./run.sh code cpgo --client)"
$C call hosts/list
$C turn -host mac -runtime claude -cwd /tmp/run-cpgo/work -allow 'Write hello.txt.'   # mkdir and git init the folder first
```

**F. The tests**, using the "build" lease:

```sh
./minio.sh up; eval "$(./minio.sh env)"; ./go.sh test ./...
```

**Clean up:**

```sh
./gohosts.sh down cpgo; ./run.sh down cpgo; ./run.sh down cpgok; ./minio.sh down
```

## Recommendation: go on

**Go on, with the control plane second, after the Linux host (#1125), as that lane recommends.** These are the reasons:

- **The wire held.** Today's window and Swift host, and the #1125 Go host, worked with no change and on the first try once the bytes matched. The Swift vectors (`Web/test/vectors.json`) and the record JSON were enough to find every difference. Keep them, and the #1125 schema, as the shared contract while two languages speak it.
- **It is a server, and Go is good at servers.** The binary is 24 MB, against a 107 MB image. It builds in 20–30 s in a stock container, against minutes for Swift on Linux. It holds what it needs with `net/http`, `crypto/*` and one WebSocket library. The cloud copy (#61) is where this pays.
- **The libraries were thinner than hoped, but none of them blocked.** `gocloud.dev/blob` needed three workarounds for conditional writes (If-Match, the write's tag, and 409). `secrets` is only wrap and unwrap. Count on writing about as much code round them as in Swift's own S3 signer.
- **What is left is the bulk.** The parts ported here are about 6,800 lines of Swift. The parts not ported (workspace providers, ssh installs and tunnels, Slack, copies and handover) are about 5,900 more, and they are the parts with the most behaviour. Port them by area, each with its Swift tests, while the Swift control plane stays the one that ships.

**Before going on:** find out whether DigitalOcean Spaces honours If-Match and If-None-Match (#61). Both control planes depend on it, and a store that ignores them is refused at start.

## Known broken or left out

- **Several copies over one store.** Not ported: no peer links, no leases, no handover, no forwarding. A Go copy is a single copy, like Agents Host's today.
- **Detect Servers, Update and Check Again** (`hosts/detect`, `hosts/sshHosts`, `hosts/update`, `hosts/checkAgain`): these answer "This control plane cannot do that yet." Add a Server over ssh works (stage 6), except through a bastion's tunnel.
- **Workspace providers, kept requests, Write It for Me** (`providers/*`, `hosts/start`, …): these answer "Workspace providers need a control plane with one copy, for now." The words are wrong here (it *is* one copy), but they are what the window already shows.
- **Channels (Slack).** `channels/get` says it is unavailable, and `channels/set` refuses.
- **Notices to phones.** `attention/need` is acknowledged and dropped: no relay host is told, and nothing is sealed to a device.
- **`hosts/lastHeard`** answers with nothing kept, so a window that opens while a host is offline sees its lists empty until the host is back.
- **Bonjour.** A window on another Mac can't find the control plane by itself. Use a code.
- **The MCP Apps sandbox proxy** (#187) is served with a fixed CSP, not the view's own.
- **The window was never seen on screen** (the Mac was locked), and neither was the page in a real browser.
- **SSE-KMS buckets on AWS** would break conditional writes (see gocloud above). DigitalOcean Spaces (#61) was not tried. Whether it honours If-Match at all is the first thing to find out, for Swift as much as for Go.
