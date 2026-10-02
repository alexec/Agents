---
diataxis: how-to
devices: [server]
description: Run the control plane as several copies over one bucket, behind a load balancer, so it stays up when one copy or your Mac stops.
---

# Run the control plane as several copies

A control plane on your Mac stops being reachable whenever the Mac sleeps. Run on Linux
instead, as two or more copies sharing one bucket behind a load balancer, it stays up: if
one copy stops, its windows, phones and hosts reconnect to another within seconds, and no
agent loses work. See [The control plane](../explanation/control-plane.md) for why.

The control plane is `agents-control`, a single program built as a container image. There
is no published image yet: you build it from the source.

## Before you start

- A clone of the Agents repository on a Mac with Xcode, and the swift.org toolchain and
  Static Linux SDK that match Xcode's Swift, to build the Linux program.
- Docker, or anywhere else that runs containers.
- An S3-compatible bucket (Amazon S3, Cloudflare R2 or MinIO, for example) and an access
  key for it. It must support conditional writes, which the copies rely on so that two of
  them never overwrite each other's change.
- One stable name for the control plane, such as `agents.example.com`, and a load
  balancer or TLS proxy for it that passes WebSockets through.

## Steps

### Try it on one machine first

The repository's `deploy/` folder runs a bucket (MinIO), three copies and Caddy in front of
them, on one machine with Docker.

1. Build the Linux program, for the machine's own architecture:

   ```sh
   scripts/build-linux-control.sh aarch64      # x86_64 on an Intel machine
   ```

2. Make the secrets: the control plane's key, and a certificate for Caddy with its pin.

   ```sh
   deploy/make-secrets.sh
   ```

3. Start everything:

   ```sh
   docker compose -f deploy/compose.yaml up -d --build
   ```

   The control plane is at `https://127.0.0.1:8443`.

4. Ask any copy for a code to pair a window with:

   ```sh
   docker compose -f deploy/compose.yaml exec -T cp1 /agents-control code --client
   ```

   Paste it into Agents; see [Connect a window or phone](connect-a-window-or-phone.md).
   For a host, ask for `code --host` instead.

5. To see it keep going, stop a copy with `docker compose -f deploy/compose.yaml stop cp1`.
   The window and its hosts reconnect to another copy.

This set-up's address is `127.0.0.1`, so only this machine can use it. Its keys are for
trying it out only.

### Run it on your own hosting

1. Build the image, from the repository's top folder:

   ```sh
   scripts/build-linux-control.sh x86_64       # or aarch64, for the machines it runs on
   docker build -f deploy/Containerfile -t agents-control deploy
   ```

2. Make the control plane's private key, 32 random bytes, once:

   ```sh
   head -c 32 /dev/urandom > control-key
   ```

   Put it in your platform's secrets. Every copy gets the same key. It is never written to
   the bucket, and anyone who has it can pose as your control plane.

3. Check the bucket can be used. With the bucket's settings from the table below in a file
   such as `store.env`:

   ```sh
   docker run --rm --env-file store.env agents-control store check --store s3://my-agents/control
   ```

4. Start two or more copies of the image. Give each one:

   | Variable | What it is |
   |---|---|
   | `AGENTS_STORE` | the bucket and a prefix, such as `s3://my-agents/control` |
   | `AGENTS_STORE_ENDPOINT` | the bucket's endpoint, if it is not Amazon S3 |
   | `AGENTS_STORE_REGION` | the bucket's region, if not `us-east-1` |
   | `AGENTS_STORE_PATH_STYLE` | `1` for MinIO and others that want path-style addresses |
   | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | the bucket's keys, from your secrets |
   | `AGENTS_CONTROL_KEY_FILE` | the path the key from step 2 is mounted at (or `AGENTS_CONTROL_KEY`, the key itself in base64url) |
   | `AGENTS_CONTROL_URL` | the one address every window, phone and host is given, such as `https://agents.example.com` |
   | `AGENTS_CONTROL_PEER_URL` | where the other copies reach this one, such as `http://cp2.internal:8791` |
   | `AGENTS_CONTROL_NAME` | the name windows and phones show for it |

   Each copy listens on port 8791. The copies must be able to reach each other at their
   peer addresses.

5. Put the load balancer in front, on the name in `AGENTS_CONTROL_URL`:
   - terminate TLS there, and send connections to any copy on port 8791;
   - pass WebSockets through;
   - use `/readyz` as the health check, so a copy that cannot reach the bucket gets no new
     connections.

   If its certificate is publicly trusted, you are done: codes carry no pin, and renewals
   need nothing (see [Run the control plane in the cloud](run-the-control-plane-in-the-cloud.md),
   which uses Caddy and Let's Encrypt). If it is self-signed, give every
   copy its pin as `AGENTS_CONTROL_PIN`, so every code carries it; `deploy/make-secrets.sh`
   shows how to work a pin out.

6. Make a code in any copy, and pair a window with it. With Docker, for a copy named
   `cp1`:

   ```sh
   docker exec cp1 /agents-control code --client
   ```

   From then on, make codes from that window: see
   [Connect a window or phone](connect-a-window-or-phone.md) and
   [Add a server](add-a-server.md).

## What to know

- If the bucket cannot be reached, live connections carry on, but pairing, forgetting a client
  and adding or removing a host are refused until it is back. Nothing is half done.
- In any copy, `/agents-control hosts` and `/agents-control clients` list what the store
  holds.
- To move a control plane from one store to another, `/agents-control store copy --from
  <store> --to <store>` copies every record.
- The relay that lets devices reach you through iCloud, and notifications, need a Mac host.
  Without one, your devices reach the control plane only at its address, and get no
  notifications.

## Related

- [Set up Agents on this Mac](set-up-on-this-mac.md), for a single copy on a Mac.
- [The control plane](../explanation/control-plane.md).
