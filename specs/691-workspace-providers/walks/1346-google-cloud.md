# Walk: Google Cloud, a Compute Engine VM and a workstation (#1346, 2026-10-19)

On the Go control plane, in the Google Cloud project `agents-control`, as its service account
(`~/.agents/secrets/gcp-agents-control.json`, in a throwaway `CLOUDSDK_CONFIG`). Every resource
was named `w1346-…` and labelled, and was deleted after the walk. The VM `agents-control` (the
live control plane, us-west1-b) was not touched.

## Set-up

- **Control plane:** `run-app` (`launch.sh --slug w1346 --no-window`), started with
  `--control-env AGENTS_SSH_CONFIG=/tmp/w1346/ssh_config`: the walk's own key and known_hosts.
  Nothing in `~/.ssh` was changed.
- **Driving:** the control plane's own calls, as the Mac window makes them (`operator.mjs`):
  `providers/add`, `providers/create`, `hosts/install` (with a tunnel: the scratch control plane
  is on this Mac's loopback), `hosts/link`, `hosts/stop`, `hosts/start`,
  `hosts/deleteWorkspace`.
- **Key:** the service account's JSON key, given only as the scratch provider's secret
  `GOOGLE_SERVICE_ACCOUNT_KEY`, and removed with the scratch set-up.

## Compute Engine: the `gcp-compute-api` preset

`{"preset":"gcp-compute-api","project":"agents-control","zone":"us-west1-b","label":"agents-walk-1346","user":"agents","sshKeys":["ssh-ed25519 … w1346-walk"]}`

| Step | Result |
|---|---|
| Add | **Passed.** Listed through the API with a token from the key: 0 workspaces. The unlabelled `agents-control` VM is not listed. |
| New Workspace (`e2-small`) | **Passed.** `create w1346-vm … ok in 1s, joining on first boot`. The VM was RUNNING with the label at once, and listed `running`, ssh `agents@<external IP>`. |
| First boot | **Passed.** The startup script made `agents` with the walk's key, turned on linger, and ran the first-boot install, which could not reach a control plane on this Mac's loopback (`curl: (7) Failed to connect to 127.0.0.1`), as expected. `agents` is in no group but its own: `sudo -n true` asks for a password. |
| Install over ssh, tunnel | **Passed.** `tunnel to w1346vm: up`, and the host joined (Linux x86-64) about 50 s after the call. |
| Link | **Passed.** `canStop`, `startWhenUsed`. A project added on the host's daemon (`projects/add`, `files/browse`) answered. |
| Stop | **Passed.** `ok in 16s`, TERMINATED. The host showed `stopped`, with `canStart`. |
| Start | **Passed.** `ok in 123s`: the start, the tunnel up again at 56 s, and `ssh start w1346vm: ok` at 2 min. The host was `online`. |
| Delete Workspace | **Passed.** `delete … ok`, the tunnel let go ("no longer a host"), and the VM and its boot disk were gone 20 s later. |

No turn was run: it needs a Claude sign-in on the VM, and lending this Mac's to a cloud VM was
not part of the walk. The Docker and Codespaces walks ran turns on the same host code.

### Found, filed

- **#1691**: the VM kept its external address over the Stop and Start, but an ephemeral address
  can change at Start. The listing then gives the new one, but the tunnel and the ssh start dial
  the address the host was installed over. The Add Provider help says to give the VMs a static
  address until then.

### Fixed in this branch

- The WIP put the walk's key in Google's `ssh-keys` metadata. The guest agent makes that user a
  member of `google-sudoers`, so the host's user could become root. The keys now go in the
  metadata `agents-ssh-keys`, which the startup script copies into `agents`'s
  `authorized_keys`. The walk confirmed `agents` has no sudo.

## Workstations: the `gcloud-workstations` preset

The Workstations API was turned on for the walk. The smallest set-up: cluster `w1346-cluster`
(us-west1, the default network), config `w1346-config` (e2-standard-2, a 10 GB pd-balanced
disk, 30 minutes idle, 1 hour at most; pd-standard must be 200 GB or more), workstation
`w1346-ws` on the default image (Ubuntu 24.04, x86_64). All labelled `agents-walk=1346`.
ssh reached it through `gcloud workstations start-tcp-tunnel w1346-ws 22
--local-host-port=localhost:2246`, as the host `w1346ws` in the walk's ssh config.

`{"preset":"gcloud-workstations","cluster":"w1346-cluster","config":"w1346-config","region":"us-west1","ssh":"w1346ws"}`,
with the secret `CLOUDSDK_CONFIG` set to the walk's gcloud config: a provider's commands get only
an allowed list of the control plane's variables, and its secrets.

| Step | Result |
|---|---|
| Add | **Failed, then passed.** Without a project, gcloud took its default one from the config it was given, and the Mac's had none: "Failed to find attribute [project]". **Fixed in this branch:** the preset takes `project`, and the Mac's form has it. With the walk's config: the workstation listed `running` (gcloud now prints `RUNNING`, not `STATE_RUNNING`), ssh `w1346ws`, tunnel. |
| Install over ssh, tunnel | **Passed.** The host joined 25 s after the call. The workstation's `user` has sudo: that is Google's image. |
| Link | **Passed.** `canStop`. |
| Stop | **Passed.** `ok in 7s`, STOPPED. |
| Start | **Failed.** The workstation was RUNNING again in about 2 minutes, but the tunnel and the ssh start were refused: "The server's host key has changed since your known_hosts last saw it". A workstation's container is made again at each start, and only `/home` is kept: `/etc/ssh/ssh_host_ed25519_key` was written at that start, while `~/.agents-server` was still there. **Filed: #1701**, with a proposal: a preset says its host keys are new at each start, and after a Start the control plane made, the first ssh pins the new key. |

## Cost

- **Compute Engine:** one e2-small VM for 10 minutes (21:51–22:01) and its 20 GB boot disk:
  under $0.01.
- **Workstations:** the cluster from 22:02 until it was gone at 22:35, 33 minutes, at $0.20 an
  hour (the cluster's fee); the workstation running for about 6 minutes at about $0.07 an hour
  (e2-standard-2) and the workstation fee; the 10 GB disk for 8 minutes. About $0.12.

## Clean-up

The VM and its disk were deleted through the provider (Delete Workspace); the workstation, the
config and the cluster with `gcloud workstations … delete`. Afterwards
`gcloud compute instances list` and `gcloud compute disks list` showed only `agents-control`,
and `gcloud workstations clusters list --region us-west1` showed nothing. The Workstations API
was left on (it costs nothing without a cluster). The scratch set-up was stopped (`stop.sh`), the
walk's key, ssh config and gcloud config in `/tmp` removed, and no ssh or gcloud process of the
walk was left.
