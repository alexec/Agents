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
