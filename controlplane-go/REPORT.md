# Spike #1126: the control plane in Go

Throwaway code. It is not merged into the product. Part of #1126; the host half is #1125.

## Stages

One line for each stage, written when the stage was committed.

1. **Store: done.** `internal/store` has three stores: memory, a folder, and a bucket through `gocloud.dev/blob` + `s3blob`. The cases from `StoreConformanceTests.swift` are ported, plus a race of 20 If-Match writes. All pass on memory, the folder and MinIO (`cgr.dev/chainguard/minio`). The folder store writes the same paths and the same SHA-256 tags as the Swift `FolderStore`, so each can read the other's folder.

## Libraries and what they missed

- **gocloud.dev/blob v0.46** (v0.47 needs Go 1.26; the toolchain image is 1.25):
  - It has `IfNotExist` (If-None-Match: \*) for S3 and for files.
  - It has **no If-Match**. I worked round this: `BeforeWrite` → `As(*transfermanager.UploadObjectInput)` → set `IfMatch`. This works only on the S3 driver. On any other driver the write is refused, and the start-up probe refuses that store.
  - A write **does not return the entity tag**. The store uses the quoted MD5 of the bytes, which is the tag that S3 and MinIO give a single-part upload. With SSE-KMS on AWS the tag is not the MD5, so conditional writes against such a bucket would always conflict. This is a known gap.
  - It maps **409 ConditionalRequestConflict** (two writes that race on AWS) to `Unknown`. The store reads the smithy error code through `errors.As`.
  - `fileblob` has no If-Match, so the folder store is written by hand (flock, temporary file, fsync, rename, folder fsync), as in Swift.
  - `s3blob.Delete` does a HEAD before each DELETE: one more request for each delete.
