# Spike S4 — conditional writes (058, T024)

Run 2026-09-28 against MinIO in Colima. No real AWS or R2 bucket was used. For those two, the
documented behaviour is cited below.

**Verdict:** MinIO honours `If-None-Match: *` and `If-Match` on `PutObject` atomically. Over
two runs, 800 races each had exactly one winner (2 and 8 writers, update and create). The
hand-written SigV4 signer works. Five details need to go into `contracts/store.md`. They are
listed at the end.

## Setup

**Official MinIO images are gone.**
- `minio/minio` on Docker Hub returns "repository does not exist". MinIO removed its Docker Hub
  repos on 2026-09-11.
- `quay.io/minio/minio` answers 401.
- `dl.min.io/server/...` answers 410 Gone, with the note "The open-source MinIO Server ... [is]
  archived and no longer maintained".

The spike therefore used Chainguard's build of MinIO's last open-source source. Chainguard
builds from MinIO's own source, and its image reports
`minio version RELEASE.2026-09-22T19-25-18Z (commit-id=df34868a…)`, go1.27.1, linux/arm64:

```sh
docker pull cgr.dev/chainguard/minio:latest
# digest sha256:71674988a1c7ddd5724928633199152b11e4ddefd6c6ce2d60772ff4a8f22ca9
docker run -d --name s4-spike-minio -p 127.0.0.1:19000:9000 \
  -e MINIO_ROOT_USER=s4spike -e MINIO_ROOT_PASSWORD=s4spike-secret-123 \
  cgr.dev/chainguard/minio:latest server /tmp/data
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:19000/minio/health/live   # 200
```

The API listened on loopback only. The container was a single node with a single drive. It
was stopped and removed afterwards (`docker rm -f s4-spike-minio`).

The client is `s4.swift`, a single file with no dependencies:
- It has its own AWS SigV4 signer: CryptoKit HMAC-SHA256, region `us-east-1`, service `s3`.
- It signs `host`, `x-amz-content-sha256`, `x-amz-date`, and `if-match`/`if-none-match`
  when present.
- It sends path-style requests over an ephemeral `URLSession` with no cache.
- It creates bucket `s4-spike`. Each run uses a fresh key prefix.

```sh
swiftc -O -swift-version 5 -o .build/s4 s4.swift          # Apple Swift 6.4
S4_ENDPOINT=http://127.0.0.1:19000 S4_ACCESS_KEY=s4spike \
S4_SECRET_KEY=s4spike-secret-123 S4_BUCKET=s4-spike .build/s4
```

The output of the two runs is in `run-1.txt` and `run-2.txt`. The two runs were identical,
and each took about 19 s.

## Results

### 0. SigV4

| Check | Result |
|---|---|
| `PUT /s4-spike` (create the bucket) | **200** |
| A PUT signed with the wrong secret | **403 SignatureDoesNotMatch**, so the signer really is being checked |

### 1. `If-None-Match: *` (create once)

| Check | Result |
|---|---|
| PUT on a new key | **200**, with an ETag |
| A second PUT on the same key | **412 PreconditionFailed** |
| Body after the refused write | still the first body |

### 2. `If-Match` (compare and swap)

| Check | Result |
|---|---|
| PUT with the current ETag | **200**, and the ETag changes |
| PUT with a stale ETag | **412 PreconditionFailed**, and the body and ETag are unchanged |
| PUT with `If-Match` on a key that does not exist | **404 NoSuchKey**, *not* 412 |

### 3. Races

These are the same in both runs. Each round follows these steps:
1. Every writer uses one ETag, read just before the round.
2. All the writers PUT at once, from concurrent tasks on separate connections.
3. The key is read back afterwards.

| Race | Rounds | Exactly one winner | No winner | Several winners | Stored body and ETag are the winner's | Replies |
|---|---|---|---|---|---|---|
| `If-Match` on one lease key, 2 writers | 100 | **100** | 0 | 0 | 100 | 200×100, 412×100 |
| `If-None-Match: *` on a fresh key each round, 2 writers | 100 | **100** | 0 | 0 | 100 | 200×100, 412×100 |
| `If-Match`, 8 writers (extra) | 100 | **100** | 0 | 0 | 100 | 200×100, 412×700 |
| `If-None-Match: *`, 8 writers (extra) | 100 | **100** | 0 | 0 | 100 | 200×100, 412×700 |

MinIO never returned 409 in these races. Every loser got 412.

### 4. `DELETE` with `If-Match` (informational)

MinIO **ignores it**:

| Check | Result |
|---|---|
| `DELETE` with `If-Match: <wrong etag>` | **204**, and the object **is deleted** (a GET afterwards gives 404) |
| `DELETE` with `If-Match: <current>` | 204, deleted |
| `DELETE` with `If-Match` on a missing key | 204 |
| Unconditional `DELETE` on a missing key | 204 |

A conditional delete against MinIO is therefore *silently unconditional*.

### 5. ETag form (`If-Match` on PUT)

| Header sent | Result |
|---|---|
| Quoted, exactly as returned (`"1b26…"`) | **200** |
| Unquoted (`1b26…`) | **200**: MinIO strips the quotes |
| Weak (`W/"…"`) | **412** |
| Upper-cased hex | **412**: the match is case-sensitive |
| A well-formed but wrong ETag | 412 |
| `If-Match: *` on an existing key | 200 |
| `If-Match: *` on a missing key | 404 NoSuchKey |
| `If-None-Match: <etag>` (not `*`) on PUT | 412 when it matches the current ETag. AWS documents only `*` here, so do not use this form |
| Rewriting identical bytes | **the ETag stays the same**. The ETag is the MD5 of the body, so it is not a version counter |

### 6. The start-up probe as written in contracts/store.md rule 4

| Step | Result |
|---|---|
| Create | 200 |
| Create again | **412** |
| Delete | 204 |

The probe works as specified.

## Documented behaviour: AWS S3 and Cloudflare R2

### AWS S3

Source: the [conditional writes guide](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html).

**`If-None-Match`**
- It is supported on PutObject, CompleteMultipartUpload and CopyObject.
- It "expects the \* (asterisk) value".
- A write succeeds with 200 when the key is absent, and fails with **412** when it exists.
- "If multiple conditional writes or copies occur for the same object name, the first write
  operation to finish succeeds. Amazon S3 then fails subsequent writes with a
  `412 Precondition Failed`."
- "You can also receive a `409 Conflict` response in the case of concurrent requests if a
  delete request to an object succeeds before a conditional write ... With `PutObject`,
  uploads may be retried after receiving a `409 Conflict`."

**`If-Match`**
- A matching ETag gives 200. A mismatch gives **412**.
- "You can also receive a `409 Conflict` response in the case of concurrent requests."
- "If there's no current object version with the same name, or if the current object version
  is a delete marker, the operation fails with a `404 Not Found` error." MinIO behaved the
  same way.

**Requirements and history**
- Conditional writes require SigV4.
- `If-Match` also needs `s3:GetObject` permission.
- A bucket policy can require conditional writes with the `s3:if-none-match` and `s3:if-match`
  condition keys
  ([enforcing them](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes-enforce.html)).
- Announcements:
  - [`If-None-Match`, 2024-08](https://aws.amazon.com/about-aws/whats-new/2024/08/amazon-s3-conditional-writes/);
  - [`If-Match`, 2024-11](https://aws.amazon.com/about-aws/whats-new/2024/11/amazon-s3-functionality-conditional-writes/);
  - [enforcement by bucket policy, 2024-11](https://aws.amazon.com/about-aws/whats-new/2024/11/amazon-s3-enforcement-conditional-write-operations-general-purpose-buckets/).

**Conditional deletes**
- These exist on AWS
  ([guide](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-deletes.html);
  [general purpose buckets, 2025-09](https://aws.amazon.com/about-aws/whats-new/2025/09/amazon-s3-conditional-deletes-s3-general-purpose-buckets)).
- `If-Match: <etag>` or `If-Match: *` on DeleteObject returns 204, or **412** on a mismatch.

### Cloudflare R2

**S3 API compatibility.** The
[S3 API compatibility table](https://developers.cloudflare.com/r2/api/s3/api/) lists four
conditional headers for PutObject:
- `If-Match`;
- `If-None-Match`;
- `If-Modified-Since`;
- `If-Unmodified-Since`.

It lists none for DeleteObject.

**Release notes.** The [R2 release notes](https://developers.cloudflare.com/r2/platform/release-notes/)
say:
- 2022-05-27: "If conditional headers are provided to S3 API `UploadObject` or
  `CreateMultipartUpload` operations, and the object exists, a `412 Precondition Failed`
  status code will be returned if these checks are not met."
- 2022-07-30: conditionals accept arrays of ETags, **weak ETags** and wildcards. This differs
  from MinIO, which refuses a weak ETag.

**Consistency.** The
[consistency model](https://developers.cloudflare.com/r2/reference/consistency/) says R2 is
strongly consistent, and that for unconditional writes "the last writer to complete 'wins'".

**What R2 does not document:**
- that its conditional check is atomic against a concurrent writer;
- what `If-Match` returns on a missing key;
- whether it ever returns 409.

A
[community question](https://community.cloudflare.com/t/are-r2-conditional-putobject-predicates-atomic-for-concurrent-writers/960811)
asks the atomicity question, and the page could not be fetched (403).

**R2 is the least-proven backend.** The race test should be run once against a real R2 bucket
before anyone relies on it for leases.

## What must change

### research.md R4

**1. MinIO still conforms, but its images are gone.** The line "AWS S3, Cloudflare R2 and
MinIO all honour both headers" stands for writes. It needs two notes:
- For R2, atomicity under a race is undocumented.
- MinIO no longer ships images or binaries. The quickstart, the T068 `compose.yaml` and plan
  should name `cgr.dev/chainguard/minio` (or another maintained build), not `minio/minio`.

**2. Conditional deletes are not portable.** "No conditional delete is needed" is right.
Conditional deletes must also never be *relied on*:
- MinIO silently ignores `If-Match` on DELETE and deletes anyway.
- R2 does not document it.

### contracts/store.md

**1. Map the refusals.** Map all of the following to `StoreError.conflict`:
- **412**, for either condition;
- **409** (AWS, concurrent requests; for PutObject the doc says it may be retried, so re-read
  first);
- **404 NoSuchKey on a `.matching` put**, which means the record was deleted elsewhere.

A 404 on `.matching` must not surface as "not found" or `storeUnavailable`.

**2. Every write must change the bytes.** ETags are content hashes (MD5 on S3 and MinIO,
SHA-256 in the folder store). Writing identical bytes keeps the ETag, so A→B→A lets a stale
`If-Match` succeed (ABA).
- Every write of a record must bump `version` (records already carry `version`, per the R2
  "Keep" row).
- Every lease renewal must change `epoch` or `expires`.

The contract should say this outright.

**3. Pass ETags through untouched.** Store the ETag exactly as returned, quotes included, and
send it back as-is:
- never normalise its case;
- never add `W/`.

MinIO accepts an unquoted ETag, but that is not guaranteed elsewhere.

**4. Extend the start-up probe (rule 4).** Today it tests only `absent`.
- Add a `.matching(<stale etag>)` put that must get 412, because a store can honour one header
  and not the other.
- Optionally add a `DELETE` with a wrong `If-Match`, and log whether it was honoured. It must
  not gate start-up, since MinIO would fail it.

**5. Keep `delete(_:)` unconditional.** Nothing in the design may depend on a conditional
delete.
