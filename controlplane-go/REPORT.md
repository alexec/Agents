# Spike #1126: the control plane in Go

Throwaway code. It is not merged into the product. Part of #1126; the host half is #1125.

## Stages

One line for each stage, written when the stage was committed.

1. **Store: done.** `internal/store` has three stores: memory, a folder, and a bucket through `gocloud.dev/blob` + `s3blob`. The cases from `StoreConformanceTests.swift` are ported, plus a race of 20 If-Match writes. All pass on memory, the folder and MinIO (`cgr.dev/chainguard/minio`). The folder store writes the same paths and the same SHA-256 tags as the Swift `FolderStore`, so each can read the other's folder.

2. **Auth and join: done.** `internal/auth` does the hello/auth/ok exchange (both sides), the v2 codes, and the client, host, code and copy key derivations. It passes Swift's `Web/test/vectors.json`. `internal/records` writes the same JSON as the Swift records (ISO dates with milliseconds, UUIDs in upper case, tombstones, `rev`), and the ported `revAndTombstones` case passes. `internal/service` has the TLS WebSocket server, codes that are used once (with #212 replays), pairing, enrolment, and a `mac` home host. Tested live with **today's Swift `agentsd` and the Mac window, with no change to either**: the host enrolled as `mac` and connected, the window paired with `AGENTS_CONTROL` and opened two channels, and a Claude turn ran end to end (its permission card was answered through the control plane). `cmd/agents-control` has the same `serve --home` / `code` command line as the Swift tool, so `run.sh` can put it in place of the Swift one. (The router and the web listener are in this commit too, because the service needs them to build. Stages 3 and 5 test them.)

## Libraries and what they missed

- **gocloud.dev/blob v0.46** (v0.47 needs Go 1.26; the toolchain image is 1.25):
  - It has `IfNotExist` (If-None-Match: \*) for S3 and for files.
  - It has **no If-Match**. I worked round this: `BeforeWrite` → `As(*transfermanager.UploadObjectInput)` → set `IfMatch`. This works only on the S3 driver. On any other driver the write is refused, and the start-up probe refuses that store.
  - A write **does not return the entity tag**. The store uses the quoted MD5 of the bytes, which is the tag that S3 and MinIO give a single-part upload. With SSE-KMS on AWS the tag is not the MD5, so conditional writes against such a bucket would always conflict. This is a known gap.
  - It maps **409 ConditionalRequestConflict** (two writes that race on AWS) to `Unknown`. The store reads the smithy error code through `errors.As`.
  - `fileblob` has no If-Match, so the folder store is written by hand (flock, temporary file, fsync, rename, folder fsync), as in Swift.
  - `s3blob.Delete` does a HEAD before each DELETE: one more request for each delete.
