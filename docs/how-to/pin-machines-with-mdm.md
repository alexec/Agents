---
diataxis: how-to
devices: [mac]
description: Pin every Mac and Linux server of your organisation to one control plane, with a configuration profile or /etc/agents/policy.json, and make them run nothing until they have joined it.
---

# Pin machines with MDM

An organisation's IT can say which control plane its machines join (#998). On a Mac, a
configuration profile does it. On a Linux server, the file `/etc/agents/policy.json` does
it. Both carry three settings, and only three:

| Setting | On a Mac (key) | In `/etc/agents/policy.json` | What it does |
|---|---|---|---|
| The address | `ControlPlaneAddress` | `controlPlane.address` | The control plane's host name, such as `control.acme.dev`, or its URL. |
| The key | `ControlPlaneKey` | `controlPlane.key` | The control plane's key. Copy it from a code (see below). |
| Must join | `MustJoin` | `mustJoin` | `true`: the machine runs nothing until it has joined that control plane. |

The rules (modes, budgets, runtimes and the kill switch) come only from the control plane.
See [Set an organisation policy](set-an-organisation-policy.md). A profile or a file with
any other key is still used, but that key is ignored, and the machine's log says so once.

## What a pinned machine does

- It joins, and pairs with, only the pinned control plane. A code or an address of another
  control plane is refused with "Set by your organisation. This Mac may join
  control.acme.dev only."
- On the Mac, **Run it here** in Agents Host is refused: a control plane of its own is
  another control plane. In the window, **Forget This Mac…** is refused while the window
  is paired with the pinned control plane.
- With **Must join**, until the machine has joined the pinned control plane, it starts no
  agent, shell or workflow. Agents Host shows "Your organisation requires this Mac to join
  control.acme.dev." Each client says the same when it asks for work. A workflow's trigger
  is let go, not kept: nothing runs by itself once the machine has joined.

## Find the control plane's key

The key is in every code that the control plane makes. A code looks like this:

```text
agents-control:2:h:-:<key>:<secret>:<address>:<pin>:<name>
```

Copy the fifth field, `<key>`. For example, make a machine code in **Settings ▸ Machines ▸
Add a Mac**, copy the field, and then let the code expire. You can also give the key's
short id: the first 8 bytes of the SHA-256 of the key, base64url. Policy signatures use
the same id.

When the control plane's key is rotated, put the new key in the profile within 30 days.
Until then, a machine that joined with the old key still counts as joined.

You can give only the address, or only the key. The address is easier to read. The key is
stronger, because nobody else can have it.

## Pin a Mac

Agents Host and the window read their own preferences domains:
`com.alexecollins.agents.host` and `com.alexecollins.agents.store`. One profile sets both.
Only the values that the profile forces count. A person's own `defaults write` pins
nothing.

1. Copy this profile, and put your address, your key and your choice of must join in both
   payloads. Give each `PayloadUUID` a new UUID (`uuidgen`).

    ```xml
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>PayloadType</key>
        <string>Configuration</string>
        <key>PayloadVersion</key>
        <integer>1</integer>
        <key>PayloadIdentifier</key>
        <string>dev.acme.agents.pin</string>
        <key>PayloadUUID</key>
        <string>8C1B1E0A-0000-4000-8000-000000000001</string>
        <key>PayloadDisplayName</key>
        <string>Agents: join control.acme.dev</string>
        <key>PayloadScope</key>
        <string>User</string>
        <key>PayloadContent</key>
        <array>
            <dict>
                <key>PayloadType</key>
                <string>com.alexecollins.agents.host</string>
                <key>PayloadVersion</key>
                <integer>1</integer>
                <key>PayloadIdentifier</key>
                <string>dev.acme.agents.pin.host</string>
                <key>PayloadUUID</key>
                <string>8C1B1E0A-0000-4000-8000-000000000002</string>
                <key>ControlPlaneAddress</key>
                <string>control.acme.dev</string>
                <key>ControlPlaneKey</key>
                <string>BOn…the key from a code…</string>
                <key>MustJoin</key>
                <true/>
            </dict>
            <dict>
                <key>PayloadType</key>
                <string>com.alexecollins.agents.store</string>
                <key>PayloadVersion</key>
                <integer>1</integer>
                <key>PayloadIdentifier</key>
                <string>dev.acme.agents.pin.window</string>
                <key>PayloadUUID</key>
                <string>8C1B1E0A-0000-4000-8000-000000000003</string>
                <key>ControlPlaneAddress</key>
                <string>control.acme.dev</string>
                <key>ControlPlaneKey</key>
                <string>BOn…the key from a code…</string>
                <key>MustJoin</key>
                <true/>
            </dict>
        </array>
    </dict>
    </plist>
    ```

2. Push it with your MDM to the Macs that use Agents.
3. On a Mac, quit Agents Host and open it again, or wait for its next start. Agents Host
   reads the profile at each start of the machine.
4. Join as usual: paste a machine code of the pinned control plane in Agents Host, under
   **Join one elsewhere**. See [Add a machine](add-a-machine.md) for codes.

## Pin a Linux server

1. As root, write `/etc/agents/policy.json`:

    ```json
    {
      "controlPlane": {
        "address": "control.acme.dev",
        "key": "BOn…the key from a code…"
      },
      "mustJoin": true
    }
    ```

2. Make root its owner, and let nobody else write it:

    ```sh
    sudo chown root /etc/agents/policy.json
    sudo chmod 644 /etc/agents/policy.json
    ```

    `agentsd` uses the file only when root owns it and neither its group nor others can
    write it. Otherwise it logs why, and uses no pin.

3. Restart the machine's `agentsd`: `systemctl --user restart agents-host`. It reads the
   file at each start.

When both are there, the file wins over a Mac's profile.

## What this does not protect against

`agentsd` and Agents Host run as the user of the machine, and never ask for admin rights.
They read the profile and the file, and never write them. A user who changes the program
can avoid the pin. The pin stops mistakes and ordinary use, as the policy does. See
[Organisation policy](../explanation/organisation-policy.md).

## See also

- [Set an organisation policy](set-an-organisation-policy.md): the rules every machine
  follows, and the kill switch.
- [Organisation policy](../explanation/organisation-policy.md): why the rules come from the
  control plane, and what they do not protect against.
