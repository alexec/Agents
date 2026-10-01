// Spike S4 (058, T024): S3 conditional writes against an S3-compatible endpoint.
// A hand-written AWS SigV4 signer (CryptoKit HMAC-SHA256) over URLSession, path-style.
//
//   swiftc -O -o .build/s4 s4.swift
//   S4_ENDPOINT=http://127.0.0.1:19000 S4_ACCESS_KEY=... S4_SECRET_KEY=... S4_BUCKET=s4-spike .build/s4
//
// Prints one line per check and exits non-zero if any required check fails.

import CryptoKit
import Foundation

// MARK: - SigV4

struct Signer {
    let accessKey: String
    let secretKey: String
    let region: String
    let service = "s3"

    static func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static func sha256Hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    static func hmac(_ key: Data, _ msg: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
    }

    /// RFC 3986 unreserved characters are left alone; everything else is %XX (upper case).
    static func uriEncode(_ s: String, encodeSlash: Bool) -> String {
        var out = ""
        for b in s.utf8 {
            let c = Character(UnicodeScalar(b))
            if c.isASCII && (c.isLetter || c.isNumber || "-._~".contains(c)) || (!encodeSlash && c == "/") {
                out.append(c)
            } else {
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    func sign(_ req: inout URLRequest, body: Data, now: Date = Date()) {
        let url = req.url!
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = fmt.string(from: now)
        let day = String(amzDate.prefix(8))
        let payloadHash = Signer.sha256Hex(body)
        var host = url.host!
        if let port = url.port { host += ":\(port)" }

        req.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        req.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        // Sign host, x-amz-*, and the conditional headers when present (so a proxy cannot strip them).
        var headers: [(String, String)] = [("host", host),
                                           ("x-amz-content-sha256", payloadHash),
                                           ("x-amz-date", amzDate)]
        for name in ["if-match", "if-none-match"] {
            if let v = req.value(forHTTPHeaderField: name) { headers.append((name, v.trimmingCharacters(in: .whitespaces))) }
        }
        headers.sort { $0.0 < $1.0 }
        let canonicalHeaders = headers.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = headers.map(\.0).joined(separator: ";")

        let path = url.path.isEmpty ? "/" : url.path   // already-decoded path
        let canonicalURI = Signer.uriEncode(path, encodeSlash: false)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var pairs: [(String, String)] = []
        for item in query {
            pairs.append((Signer.uriEncode(item.name, encodeSlash: true), Signer.uriEncode(item.value ?? "", encodeSlash: true)))
        }
        pairs.sort { (a: (String, String), b: (String, String)) -> Bool in a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }
        let canonicalQuery: String = pairs.map { (p: (String, String)) -> String in p.0 + "=" + p.1 }.joined(separator: "&")

        let canonicalRequest = [req.httpMethod ?? "GET", canonicalURI, canonicalQuery,
                                canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope,
                            Signer.sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")
        var k = Signer.hmac(Data("AWS4\(secretKey)".utf8), day)
        k = Signer.hmac(k, region)
        k = Signer.hmac(k, service)
        k = Signer.hmac(k, "aws4_request")
        let signature = Signer.hex(Signer.hmac(k, stringToSign))
        req.setValue("AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
                     forHTTPHeaderField: "Authorization")
    }
}

// MARK: - Client

struct Reply {
    let status: Int
    let etag: String?
    let body: Data
    var text: String { String(decoding: body, as: UTF8.self) }
    /// S3 error code out of the XML body, if any.
    var code: String? {
        guard let r = text.range(of: "<Code>"), let e = text.range(of: "</Code>") else { return nil }
        return String(text[r.upperBound..<e.lowerBound])
    }
    var brief: String { "\(status)" + (code.map { " \($0)" } ?? "") }
}

final class S3 {
    let endpoint: URL
    let bucket: String
    let signer: Signer
    let session: URLSession

    init(endpoint: URL, bucket: String, signer: Signer) {
        self.endpoint = endpoint
        self.bucket = bucket
        self.signer = signer
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 16
        session = URLSession(configuration: cfg)
    }

    func url(_ key: String?) -> URL {
        var u = endpoint.appendingPathComponent(bucket)
        if let key { u = u.appendingPathComponent(key) }
        return u
    }

    func send(_ method: String, _ key: String?, body: Data = Data(), headers: [String: String] = [:]) async throws -> Reply {
        var req = URLRequest(url: url(key))
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if method == "PUT" { req.httpBody = body }
        signer.sign(&req, body: body)
        let (data, resp) = try await session.data(for: req)
        let http = resp as! HTTPURLResponse
        return Reply(status: http.statusCode, etag: http.value(forHTTPHeaderField: "ETag"), body: data)
    }

    func put(_ key: String, _ body: String, _ headers: [String: String] = [:]) async throws -> Reply {
        try await send("PUT", key, body: Data(body.utf8), headers: headers)
    }
    func get(_ key: String) async throws -> Reply { try await send("GET", key) }
    func delete(_ key: String, _ headers: [String: String] = [:]) async throws -> Reply {
        try await send("DELETE", key, headers: headers)
    }
}

// MARK: - Checks

let env = ProcessInfo.processInfo.environment
let s3 = S3(endpoint: URL(string: env["S4_ENDPOINT"] ?? "http://127.0.0.1:19000")!,
            bucket: env["S4_BUCKET"] ?? "s4-spike",
            signer: Signer(accessKey: env["S4_ACCESS_KEY"]!, secretKey: env["S4_SECRET_KEY"]!,
                           region: env["S4_REGION"] ?? "us-east-1"))
let rounds = Int(env["S4_ROUNDS"] ?? "100")!
let run = String(UUID().uuidString.prefix(8)).lowercased()
var failures = 0

func check(_ id: String, _ ok: Bool, _ detail: String, required: Bool = true) {
    let tag = ok ? "PASS" : (required ? "FAIL" : "NOTE")
    if !ok && required { failures += 1 }
    print("[\(tag)] \(id): \(detail)")
}

func unquote(_ e: String) -> String { e.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }

// 0. Bucket (also proves the SigV4 signer: MinIO rejects a bad signature with 403).
let mk = try await s3.send("PUT", nil)
check("0 bucket", mk.status == 200 || mk.code == "BucketAlreadyOwnedByYou", "PUT /\(s3.bucket) -> \(mk.brief)")
let badSigner = S3(endpoint: s3.endpoint, bucket: s3.bucket,
                   signer: Signer(accessKey: s3.signer.accessKey, secretKey: "wrong", region: "us-east-1"))
let bad = try await badSigner.put("\(run)/badsig", "x")
check("0 sigv4-negative", bad.status == 403, "PUT with a wrong secret -> \(bad.brief) (expect 403 SignatureDoesNotMatch)")

// 1. If-None-Match: * create-once.
let k1 = "\(run)/create-once.json"
let c1 = try await s3.put(k1, "first", ["If-None-Match": "*"])
check("1a create", c1.status == 200 && c1.etag != nil, "PUT If-None-Match:* on a new key -> \(c1.brief), ETag \(c1.etag ?? "nil")")
let c2 = try await s3.put(k1, "second", ["If-None-Match": "*"])
check("1b create again", c2.status == 412, "second PUT If-None-Match:* -> \(c2.brief) (expect 412)")
let g1 = try await s3.get(k1)
check("1c unchanged", g1.text == "first", "body after refused create = \"\(g1.text)\"")

// 2. If-Match update.
let e0 = c1.etag!
let u1 = try await s3.put(k1, "v2", ["If-Match": e0])
check("2a update", u1.status == 200 && u1.etag != nil && u1.etag != e0,
      "PUT If-Match:<current> -> \(u1.brief), ETag \(e0) -> \(u1.etag ?? "nil")")
let u2 = try await s3.put(k1, "v3", ["If-Match": e0])
check("2b stale", u2.status == 412, "PUT If-Match:<stale> -> \(u2.brief) (expect 412)")
let g2 = try await s3.get(k1)
check("2c unchanged", g2.text == "v2" && g2.etag == u1.etag, "body after refused update = \"\(g2.text)\", GET ETag \(g2.etag ?? "nil")")
let u3 = try await s3.put("\(run)/missing.json", "x", ["If-Match": e0])
check("2d if-match absent key", u3.status == 404 || u3.status == 412,
      "PUT If-Match on a key that does not exist -> \(u3.brief)", required: false)
print("[INFO] 2d detail: \(u3.brief)")

// 5. ETag quoting.
let cur = u1.etag!
let q1 = try await s3.put(k1, "v3", ["If-Match": unquote(cur)])
print("[INFO] 5a If-Match unquoted \(unquote(cur)) -> \(q1.brief)")
let afterQ1 = q1.status == 200 ? q1.etag! : cur
let q2 = try await s3.put(k1, "v4", ["If-Match": afterQ1])
print("[INFO] 5b If-Match quoted \(afterQ1) -> \(q2.brief)")
let afterQ2 = q2.status == 200 ? q2.etag! : afterQ1
let q3 = try await s3.put(k1, "v5", ["If-Match": "W/" + afterQ2])
print("[INFO] 5c If-Match weak W/\(afterQ2) -> \(q3.brief)")
let afterQ3 = q3.status == 200 ? q3.etag! : afterQ2
let q4 = try await s3.put(k1, "v6", ["If-Match": "*"])
print("[INFO] 5d If-Match:* on an existing key -> \(q4.brief)")
let q5 = try await s3.put("\(run)/nope-star.json", "x", ["If-Match": "*"])
print("[INFO] 5e If-Match:* on a missing key -> \(q5.brief)")
let q6 = try await s3.put(k1, "v7", ["If-None-Match": q4.etag ?? afterQ3])
print("[INFO] 5f If-None-Match:<etag> (not *) on PUT -> \(q6.brief)")
let q7 = try await s3.put(k1, "v8", ["If-Match": "\"00000000000000000000000000000000\""])
print("[INFO] 5g If-Match with a well-formed but wrong ETag -> \(q7.brief)")
let q8 = try await s3.put(k1, "v9", ["If-Match": (q6.etag ?? q4.etag ?? afterQ3).uppercased()])
print("[INFO] 5h If-Match with the ETag upper-cased -> \(q8.brief)")
let same1 = try await s3.get(k1)
let same2 = try await s3.put(k1, same1.text, ["If-Match": same1.etag!])
print("[INFO] 5i rewrite identical bytes: ETag \(same1.etag!) -> \(same2.etag ?? "nil") (\(same2.brief)) — same-content writes \(same1.etag == same2.etag ? "keep" : "change") the ETag")

// 4. DELETE with If-Match (informational).
let k4 = "\(run)/delete-me.json"
let d0 = try await s3.put(k4, "d", ["If-None-Match": "*"])
let d1 = try await s3.delete(k4, ["If-Match": "\"00000000000000000000000000000000\""])
let d1g = try await s3.get(k4)
print("[INFO] 4a DELETE If-Match:<wrong> -> \(d1.brief); object afterwards GET \(d1g.status)")
let d2 = try await s3.delete(k4, ["If-Match": d0.etag!])
let d2g = try await s3.get(k4)
print("[INFO] 4b DELETE If-Match:<current> -> \(d2.brief); object afterwards GET \(d2g.status)")
let d3 = try await s3.delete("\(run)/never.json", ["If-Match": d0.etag!])
print("[INFO] 4c DELETE If-Match on a missing key -> \(d3.brief)")
let d4 = try await s3.delete("\(run)/never.json")
print("[INFO] 4d DELETE unconditional on a missing key -> \(d4.brief)")

// 3. Races.
struct Tally { var rounds = 0, oneWinner = 0, zero = 0, many = 0, contentOK = 0; var statuses: [String: Int] = [:] }

func race(writers: Int, rounds: Int, create: Bool) async throws -> Tally {
    var t = Tally()
    let lease = "\(run)/leases/host-\(writers)w.json"
    if !create { _ = try await s3.put(lease, "seed", ["If-None-Match": "*"]) }
    for r in 0..<rounds {
        let key = create ? "\(run)/codes/r\(writers)w-\(r).spent" : lease
        var headers = ["If-None-Match": "*"]
        if !create {
            let cur = try await s3.get(key)   // every writer "read" the same ETag
            headers = ["If-Match": cur.etag!]
        }
        let h = headers
        let replies = try await withThrowingTaskGroup(of: (Int, Reply).self) { g in
            for w in 0..<writers {
                g.addTask { (w, try await s3.put(key, "round \(r) writer \(w)", h)) }
            }
            var out: [(Int, Reply)] = []
            for try await x in g { out.append(x) }
            return out
        }
        for (_, rep) in replies { t.statuses[rep.brief, default: 0] += 1 }
        let winners = replies.filter { $0.1.status == 200 }
        t.rounds += 1
        switch winners.count {
        case 1: t.oneWinner += 1
        case 0: t.zero += 1
        default: t.many += 1
        }
        if winners.count == 1 {
            let (w, rep) = winners[0]
            let now = try await s3.get(key)
            if now.text == "round \(r) writer \(w)" && now.etag == rep.etag { t.contentOK += 1 }
        }
    }
    return t
}

func report(_ id: String, _ t: Tally) {
    let stats = t.statuses.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
    check(id, t.oneWinner == t.rounds && t.contentOK == t.rounds,
          "\(t.rounds) rounds: exactly-one-winner \(t.oneWinner), none \(t.zero), several \(t.many), stored body+ETag = winner's \(t.contentOK); replies \(stats)")
}

report("3a If-Match race, 2 writers", try await race(writers: 2, rounds: rounds, create: false))
report("3b If-None-Match race, 2 writers", try await race(writers: 2, rounds: rounds, create: true))
report("3c If-Match race, 8 writers (extra)", try await race(writers: 8, rounds: rounds, create: false))
report("3d If-None-Match race, 8 writers (extra)", try await race(writers: 8, rounds: rounds, create: true))

// The start-up probe from contracts/store.md rule 4, as written.
let probe = "\(run)/probe-\(UUID().uuidString)"
let p1 = try await s3.put(probe, "p", ["If-None-Match": "*"])
let p2 = try await s3.put(probe, "p", ["If-None-Match": "*"])
let p3 = try await s3.delete(probe)
check("6 start-up probe", p1.status == 200 && p2.status == 412 && p3.status == 204,
      "create \(p1.brief), create again \(p2.brief), delete \(p3.brief)")

print(failures == 0 ? "ALL REQUIRED CHECKS PASSED (run \(run))" : "\(failures) REQUIRED CHECK(S) FAILED (run \(run))")
exit(failures == 0 ? 0 : 1)
