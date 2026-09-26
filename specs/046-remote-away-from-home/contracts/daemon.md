# Contract: Daemon Methods

Three changes to `DaemonAPI`. None of them gives the daemon network code or CryptoKit: it stores
and hands out bytes.

## `relay/register` *(new)*

Said by the bridge on its mailbox connection, right after `mailbox/carry`.

```json
{ "publicKey": "<base64 X9.63, 65 bytes>" }
```

Returns `{}`. The daemon stores the key as `relayKey` in `devices.json` and keeps it until
another `relay/register` replaces it. A key that is not 65 bytes starting `0x04` is refused with
`invalidParams`.

## `devices/announce` *(reply grows)*

The request is unchanged. The reply is the `Device` record, as today, plus:

```json
{ "...Device fields...": "...", "macKey": "<base64 X9.63>" }
```

`macKey` is omitted when no bridge has registered one. Older phones ignore the extra field, and a
newer phone treats a missing `macKey` as "not paired for the relay".

## `devices/forget` *(new)*

Said by the Mac window (Settings ▸ Devices ▸ Forget).

```json
{ "id": "<device UUID>" }
```

Returns `{}`. It removes the record from `devices.json` and broadcasts:

```json
"device/changed" { "id": "<UUID>", "removed": true }
```

`DeviceNotification` gains `removed: Bool?`, and `device` becomes optional. Old clients decode a
missing `device` as a failed decode and ignore it. Forgetting an id that is not stored is `{}`,
because forgetting is idempotent.

Refused from a device connection (one that has said `surface/identify` as a device) with
`notAllowed` (**-32060**, new): a phone cannot forget itself or another phone.

## `agents/prompt` *(caller change only)*

The Remote now sends `sendID` on every prompt (R9). The method is unchanged: `once(sendID)`
already dedups it.
