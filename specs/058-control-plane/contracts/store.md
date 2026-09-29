# Contract: the store (research R4)

`ControlStore` is the only way a copy remembers anything. There are two backends with one key
layout.

```swift
protocol ControlStore: Sendable {
    func get(_ key: String) async throws -> (data: Data, etag: String)?
    /// `.absent` = create only (If-None-Match: *); `.matching(etag)` = update only (If-Match).
    func put(_ key: String, _ data: Data, when: Condition) async throws -> String   // new etag
    func delete(_ key: String) async throws
    func list(prefix: String) async throws -> [(key: String, etag: String)]
}
enum Condition { case absent, matching(String), always }
// A refused condition throws StoreError.conflict; an unreachable store throws StoreError.unavailable.
```

## Keys

All keys are under `<prefix>/v1/` (the prefix is set when the copy is started):

| Key | Written by | Condition | Read |
|---|---|---|---|
| `control.json` | first start | `absent` | every start |
| `people/<id>.json` | first start | `absent` | start |
| `clients/<uuid>.json` | pairing, setGrant, lastSeen (hourly) | `absent` on pairing, `matching` after | start, every 15 s, on event |
| `hosts/<id>.json` | enrolment, hello (version change), remove | `absent` / `matching` | the same |
| `codes/<hash>.json` | startPairing, startEnroll | `absent` | on use |
| `codes/<hash>.spent` | first use | `absent`: the winner admits | on use |
| `leases/<host>.json` | the holding copy | `absent`, or `matching` to renew or take over | on routing, on `gone` |
| `copies/<id>.json` | each copy, every 10 s | `always` (only its own key) | peer discovery, every 10 s |
| `events/<day>/<ulid>.json` | whichever copy made the change | `absent` | on (re)joining peers |

## Rules

1. **Store first.** A change a person makes is written to the store before it is broadcast.
   If the write fails, the call fails with `-32071 changedElsewhere` (a conflict) or
   `-32073 storeUnavailable`, and nothing is broadcast.
2. **Conflicts on grants and forgets.** A conflict is never retried blindly: the operator is
   told to try again. Lease renewals are retried once, after a re-read.
3. **The last operator.** It is checked against the version read (`matching`), so two copies
   cannot each remove one of the last two operators.
4. **At start-up** a copy probes the store:
   - it writes `copies/<id>.json`;
   - it creates a probe key with `absent` twice, and expects the second to conflict;
   - it puts the probe again with a stale `If-Match`, and expects a conflict;
   - it deletes the probe.

   A bucket that ignores conditions fails this probe, and the copy refuses to start.
5. **The folder backend.**
   - A key is a file path, and the ETag is SHA-256 of the contents.
   - A `put` takes `flock` on `<key>.lock`, compares, writes a temporary file, `fsync`s it and
     renames it into place.
   - It is for one machine only.
6. **The S3 backend.**
   - Plain HTTPS with SigV4, and path-style addressing if `AGENTS_STORE_PATH_STYLE=1` (MinIO).
   - Credentials come from the environment, the standard AWS files, or (in the host app) an
     inherited descriptor, and never from the store.
7. **No secrets in the store.** That means no private keys and no code secrets, only their
   hashes.
8. **What counts as a conflict** (S4). A conditional put answered 412, 409, or 404 (an
   `If-Match` on a key that is gone) throws `StoreError.conflict`.
9. **ETags verbatim.** An ETag is sent back exactly as the store gave it, quotes included.
   Weak ETags (`W/…`) are not produced by the stores tested, and are not rewritten.
10. **Every write changes the bytes.** Each put bumps `rev` (records) or `epoch` (leases).
    Identical bytes keep the same ETag, so a record that went A→B→A would let a write made
    against the first A succeed.
11. **No conditional delete.** Deleting is never conditional, because MinIO ignores `If-Match`
    on delete. Forgetting a client or removing a host puts a **tombstone** with
    `.matching(etag)`: the record with `forgotten: true` and `rev` bumped. Readers treat a
    tombstone as absent, and any copy deletes tombstones older than seven days. Spent codes,
    expired codes and old events are deleted plainly, since a race there changes nothing.

## Copying a store

`agents-control store copy --from <store> --to <store>` copies every key under `v1/`. It refuses
a destination that already has `control.json`. It is run with no copy serving (the host app
stops its copy first), and afterwards it compares the key count and each object's SHA-256.
`leases/` and `copies/` are skipped, because both are rebuilt when a copy starts. Nothing in
the store records where it lives, so a switch needs no change to any record.

## Configuration

| Variable | Meaning |
|---|---|
| `AGENTS_STORE` | `file:///path` or `s3://bucket/prefix` |
| `--store-credentials-fd` | the host app hands bucket keys through an inherited descriptor, instead of the environment |
| `AGENTS_STORE_ENDPOINT` | S3-compatible endpoint (MinIO, R2); AWS if unset |
| `AGENTS_CONTROL_KEY_FILE` / `AGENTS_CONTROL_KEY` | the control plane's private key (never in the store) |
| `AGENTS_CONTROL_URL` | the one address clients and hosts are given |
| `AGENTS_CONTROL_PEER_URL` | where other copies reach this copy |
| `AGENTS_CONTROL_TLS_CERT` / `_KEY` | set when this copy terminates TLS itself |
