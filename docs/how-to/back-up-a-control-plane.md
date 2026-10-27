---
diataxis: how-to
devices: [mac, server]
description: Back up a control plane with everything a restore needs (its store, key, secrets key and certificate), and restore it on a new Mac or machine so that every device and machine stays paired.
---

# Back up and restore a control plane

A control plane keeps its records in its **store**, and it keeps some files beside the
store. A copy of the store alone does not restore it:

- **Without the control key,** the restored control plane does not start. It says
  `this store belongs to a control plane with another key`.
- **Without the certificate,** it makes a new one. Every window, phone and machine refuses the
  new certificate (`the certificate is not the pinned one`), and each one must pair again.
- **Without the secrets key,** your secrets and the machine providers' secrets do not
  open.

`agents-control backup` puts all of these into one folder. `agents-control restore` puts
them back. This page is about the control plane. For the agents and conversations on a
machine, see [Back up and restore a machine](back-up-and-restore.md).

## What is in a backup

| In the backup | What it is |
| --- | --- |
| `store/` | Every record: clients, machines, people, settings, and your and the providers' secrets, sealed. Machine records are under `v1/machines/`. On a cloud machine, the control key sealed by its KMS too. |
| `control-key` | The control key, when it is in a file or handed in (a Mac). |
| `secrets-key` | The key that seals secrets on a Mac. A cloud machine uses its KMS instead. |
| `tls/cert.pem`, `tls/key.pem` | The certificate that every device and machine is pinned to, when the control plane makes its own. |
| `apns.p8` | The APNs key, when there is one. |
| `backup.json` | When the backup was made, and what is in it. |

The backup holds keys in clear. Keep it as safe as the control plane's own folder: on an
encrypted disk, or in an encrypted archive. Never put it in a shared or public place.

The 0.11.2 store uses `v1/machines/` for machine records. Older builds used
`v1/hosts/`. You do not move it: when the control plane opens a folder store that has
only `v1/hosts/`, it renames the folder to `v1/machines/` and logs one line. A restore
of an older backup puts its `v1/hosts/` records in `v1/machines/` too (#2662).

A change made while the backup runs can be missed. A change made after the backup is lost
with the restore.

## On a Mac (Agents Host)

The control plane's folder is `~/Library/Application Support/Agents Control`. Agents Host
keeps the control key in the keychain, not in that folder.

### Back up

1. In Agents Host, choose **Move to Another Machine…**, then click **Save Key…** and save
   `control-key`. Close the sheet; nothing moves.
2. In Terminal, give the key to the backup, then delete the file:

   ```sh
   control="/Applications/Agents Host.app/Contents/Helpers/agents-control"
   "$control" backup --home ~/Library/Application\ Support/Agents\ Control \
       --to /Volumes/Backup/agents-control-$(date +%F) --key-fd 3 3< control-key
   rm control-key
   ```

   It says, for example, `backed up 412 records and control-key, secrets-key, tls/cert.pem,
   tls/key.pem into /Volumes/Backup/agents-control-2026-10-21`. Give a new folder each
   time: a backup never goes over another.

If the store is in a bucket, the bucket keeps the records. The backup still copies them,
and it holds what is beside the store.

### Restore on a new Mac

Do this before Agents Host starts the control plane on the new Mac for the first time. On a
Mac that has run one already, quit Agents Host and move its `Agents Control` folder aside.

1. Install Agents Host, but do not open it yet.
2. In Terminal:

   ```sh
   control="/Applications/Agents Host.app/Contents/Helpers/agents-control"
   "$control" restore --from /Volumes/Backup/agents-control-2026-10-21 \
       --home ~/Library/Application\ Support/Agents\ Control
   ```

3. Open Agents Host. When it starts, it puts the restored `control-key` into the keychain
   and deletes the file.

Your windows, phones, iPads and machines connect again with the pairings they have. They
dial the old Mac's address, `<name>.local`. Give the new Mac the old Mac's local host name
in **System Settings ▸ General ▸ Sharing** (**Local hostname**, **Edit…**).

## On a cloud machine

On a cloud machine (the `deploy/compose.public.yaml` set-up), the control key is sealed in
the store by the machine's KMS, the secrets are sealed by the KMS too, and Caddy has a
public certificate, so no device holds a pin. The backup is then the store, with the
sealed key. Make it in the container and bring it to your Mac over ssh:

```sh
(umask 077; ssh you@agents.example.com 'cd agents && docker compose -f deploy/compose.public.yaml \
    run --rm -T --entrypoint sh control -c \
    "/agents-control backup --to /tmp/backup >&2 && tar -C /tmp/backup -cz ."' \
    > agents-control-$(date +%F).tar.gz)
```

The sealed key opens only with the same KMS key. To be able to restore without that KMS
key, also export the key itself, and keep it with the backup:

```sh
(umask 077; ssh you@agents.example.com 'cd agents && docker compose -f deploy/compose.public.yaml \
    run --rm -T control key export --key-fd 1' > control-key)
```

To restore on a new machine, set it up as in
[Run the control plane in the cloud](run-the-control-plane-in-the-cloud.md), but do not
start the control plane. Copy the archive to the machine, and restore it into the empty
store:

```sh
ssh you@agents.example.com 'cd agents && docker compose -f deploy/compose.public.yaml \
    run --rm -T --entrypoint sh control -c \
    "mkdir /tmp/backup && tar -C /tmp/backup -xz && /agents-control restore --from /tmp/backup"' \
    < agents-control-2026-10-21.tar.gz
```

With the same KMS key, start it.

With a new KMS key, add `--new-kms` to `restore`, which leaves out the key the old KMS
sealed. Then seal the exported key with the new one (`key seal --key-fd 0 < control-key`,
as in the cloud how-to), and start it. Devices and machines stay paired. The secrets that the
old KMS sealed (people's and the machine providers') do not open: give them again.

## Check a restore

After a restore, check that:

- the control plane starts, and its log says the same `pin` as before (a Mac's
  `control.log`);
- **Settings ▸ Machines** lists every machine, and they come online;
- a machine provider lists its workspaces without asking for its secrets again.

## Related

- [Back up and restore a machine](back-up-and-restore.md)
- [Run the control plane in the cloud](run-the-control-plane-in-the-cloud.md)
- [The control plane](../explanation/control-plane.md)
