import AgentsKitCore
import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

/// A store in an S3-compatible bucket (058, contracts/store.md rule 6): plain HTTPS signed
/// with SigV4, conditional puts for every change, and path-style addressing for MinIO.
///
/// Signed with `ControlAgreement`'s SHA-256 and HMAC rather than CryptoKit, so the same
/// code runs in a Linux container. Spike S4 proved the conditions on MinIO; this is its
/// signer, moved onto async-http-client.
public struct S3Store: ControlStore {
    public struct Credentials: Sendable, Equatable, Codable {
        public var accessKey: String
        public var secretKey: String
        public init(accessKey: String, secretKey: String) {
            self.accessKey = accessKey
            self.secretKey = secretKey
        }
    }

    public struct Location: Sendable, Equatable {
        /// `https://s3.eu-west-2.amazonaws.com`, or MinIO's `http://127.0.0.1:9000`.
        public var endpoint: URL
        public var bucket: String
        /// Without slashes at either end; empty for the bucket's top.
        public var prefix: String
        public var region: String
        /// `https://endpoint/bucket/key` rather than `https://bucket.endpoint/key`.
        public var pathStyle: Bool

        public init(endpoint: URL, bucket: String, prefix: String = "", region: String = "us-east-1",
                    pathStyle: Bool = false) {
            self.endpoint = endpoint
            self.bucket = bucket
            self.prefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            self.region = region
            self.pathStyle = pathStyle
        }

        /// `s3://bucket/prefix`, with the endpoint, region and addressing from the
        /// environment (contracts/store.md "Configuration").
        public init?(url: URL, environment: [String: String]) {
            guard url.scheme == "s3", let bucket = url.host, !bucket.isEmpty else { return nil }
            // Set but empty is unset: compose passes `${X:-}` through as "".
            let environment = environment.filter { !$0.value.isEmpty }
            let region = environment["AGENTS_STORE_REGION"] ?? environment["AWS_REGION"]
                ?? environment["AWS_DEFAULT_REGION"] ?? "us-east-1"
            let endpoint = environment["AGENTS_STORE_ENDPOINT"].flatMap(URL.init(string:))
                ?? URL(string: "https://s3.\(region).amazonaws.com")!
            self.init(endpoint: endpoint, bucket: bucket, prefix: url.path, region: region,
                      pathStyle: environment["AGENTS_STORE_PATH_STYLE"] == "1")
        }
    }

    public let location: Location
    let credentials: Credentials
    let client: HTTPClient
    let timeout: TimeAmount

    public init(_ location: Location, credentials: Credentials, client: HTTPClient = .shared,
                timeout: TimeAmount = .seconds(10)) {
        self.location = location
        self.credentials = credentials
        self.client = client
        self.timeout = timeout
    }

    /// The keys, in the order the contract names them: the environment, then the standard
    /// AWS file (its `default` profile, or `AWS_PROFILE`). Never the store.
    public static func credentials(environment: [String: String]) -> Credentials? {
        if let access = environment["AWS_ACCESS_KEY_ID"], let secret = environment["AWS_SECRET_ACCESS_KEY"],
           !access.isEmpty, !secret.isEmpty {
            return Credentials(accessKey: access, secretKey: secret)
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        let file = environment["AWS_SHARED_CREDENTIALS_FILE"] ?? home + "/.aws/credentials"
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        let wanted = environment["AWS_PROFILE"] ?? "default"
        var profile = ""
        var access: String?
        var secret: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { profile = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]")); continue }
            guard profile == wanted, let equals = line.firstIndex(of: "=") else { continue }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if name == "aws_access_key_id" { access = value }
            if name == "aws_secret_access_key" { secret = value }
        }
        guard let access, let secret else { return nil }
        return Credentials(accessKey: access, secretKey: secret)
    }

    // MARK: ControlStore

    public func get(_ key: String) async throws -> StoredObject? {
        let reply = try await send("GET", key: key)
        switch reply.status {
        case 200:
            guard let etag = reply.etag else { throw StoreError.unavailable("the bucket gave \(key) no ETag") }
            return StoredObject(data: reply.body, etag: etag)
        case 404: return nil
        default: throw unavailable(reply, doing: "reading \(key)")
        }
    }

    public func put(_ key: String, _ data: Data, when: StoreCondition) async throws -> String {
        var headers: [(String, String)] = [("content-type", "application/json")]
        switch when {
        case .absent: headers.append(("if-none-match", "*"))
        // Sent exactly as the bucket gave it, quotes included (rule 9).
        case .matching(let etag): headers.append(("if-match", etag))
        case .always: break
        }
        let reply = try await send("PUT", key: key, body: data, headers: headers)
        switch reply.status {
        case 200:
            guard let etag = reply.etag else { throw StoreError.unavailable("the bucket gave \(key) no ETag") }
            return etag
        // Rule 8: a condition that did not hold, however the bucket says it.
        case 412, 409: throw StoreError.conflict(key: key)
        case 404 where when != .always: throw StoreError.conflict(key: key)
        default: throw unavailable(reply, doing: "writing \(key)")
        }
    }

    public func delete(_ key: String) async throws {
        let reply = try await send("DELETE", key: key)
        guard reply.status == 204 || reply.status == 200 || reply.status == 404 else {
            throw unavailable(reply, doing: "deleting \(key)")
        }
    }

    public func list(prefix: String) async throws -> [StoredKey] {
        var found: [StoredKey] = []
        var token: String?
        repeat {
            var query = [("list-type", "2"), ("prefix", objectKey(prefix))]
            if let token { query.append(("continuation-token", token)) }
            let reply = try await send("GET", key: nil, query: query)
            guard reply.status == 200 else { throw unavailable(reply, doing: "listing \(prefix)") }
            let page = ListPage(xml: String(decoding: reply.body, as: UTF8.self))
            let strip = location.prefix.isEmpty ? 0 : location.prefix.count + 1
            found += page.objects.map { StoredKey(key: String($0.key.dropFirst(strip)), etag: $0.etag) }
            token = page.next
        } while token != nil
        return found
    }

    // MARK: Requests

    struct Reply {
        var status: Int
        var etag: String?
        var body: Data
        /// S3's error code, out of the XML body.
        var code: String? {
            let text = String(decoding: body, as: UTF8.self)
            guard let start = text.range(of: "<Code>"), let end = text.range(of: "</Code>") else { return nil }
            return String(text[start.upperBound..<end.lowerBound])
        }
    }

    func objectKey(_ key: String) -> String {
        location.prefix.isEmpty ? key : location.prefix + "/" + key
    }

    private func unavailable(_ reply: Reply, doing what: String) -> StoreError {
        .unavailable("the bucket answered \(reply.status)\(reply.code.map { " \($0)" } ?? "") \(what)")
    }

    func send(_ method: String, key: String?, body: Data = Data(), headers extra: [(String, String)] = [],
              query: [(String, String)] = [], now: Date = Date()) async throws -> Reply {
        let signed = request(method, key: key, body: body, headers: extra, query: query, now: now)
        var request = HTTPClientRequest(url: signed.url)
        request.method = HTTPMethod(rawValue: method)
        for (name, value) in signed.headers { request.headers.add(name: name, value: value) }
        if method == "PUT" {
            request.body = .bytes(ByteBuffer(bytes: body))
            request.headers.replaceOrAdd(name: "content-length", value: String(body.count))
        }
        do {
            let response = try await client.execute(request, timeout: timeout)
            var buffer = try await response.body.collect(upTo: 16 * 1024 * 1024)
            let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
            return Reply(status: Int(response.status.code), etag: response.headers.first(name: "etag"), body: Data(bytes))
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.unavailable("the bucket at \(location.endpoint.host ?? "?") could not be reached: \(error)")
        }
    }

    /// The signed request, apart from sending it: its URL and every header to send.
    func request(_ method: String, key: String?, body: Data, headers extra: [(String, String)],
                 query: [(String, String)], now: Date) -> (url: String, headers: [(String, String)]) {
        var host = location.endpoint.host ?? ""
        var path = location.endpoint.path.hasSuffix("/") ? String(location.endpoint.path.dropLast()) : location.endpoint.path
        if location.pathStyle {
            path += "/" + location.bucket
        } else {
            host = location.bucket + "." + host
        }
        if let key { path += "/" + objectKey(key) }
        if path.isEmpty { path = "/" }
        let authority = location.endpoint.port.map { "\(host):\($0)" } ?? host

        let amzDate = Self.amzDate(now)
        let day = String(amzDate.prefix(8))
        let payloadHash = Self.hex(ControlAgreement.sha256(body))
        var headers: [(String, String)] = [("host", authority), ("x-amz-content-sha256", payloadHash),
                                           ("x-amz-date", amzDate)]
        headers += extra.map { ($0.0.lowercased(), $0.1.trimmingCharacters(in: .whitespaces)) }
        headers.sort { $0.0 < $1.0 }
        let canonicalHeaders = headers.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = headers.map(\.0).joined(separator: ";")

        let canonicalURI = Self.uriEncode(path, encodeSlash: false)
        var pairs: [(name: String, value: String)] = []
        for (name, value) in query {
            pairs.append((Self.uriEncode(name, encodeSlash: true), Self.uriEncode(value, encodeSlash: true)))
        }
        pairs.sort { (a: (name: String, value: String), b: (name: String, value: String)) -> Bool in
            a.name == b.name ? a.value < b.value : a.name < b.name
        }
        let canonicalQuery: String = pairs.map { (pair: (name: String, value: String)) -> String in pair.name + "=" + pair.value }
            .joined(separator: "&")
        let lines: [String] = [method, canonicalURI, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash]
        let canonicalRequest = lines.joined(separator: "\n")
        let scope = "\(day)/\(location.region)/s3/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope,
                            Self.hex(ControlAgreement.sha256(Data(canonicalRequest.utf8)))].joined(separator: "\n")
        var signingKey = Self.hmac(Data("AWS4\(credentials.secretKey)".utf8), day)
        for part in [location.region, "s3", "aws4_request"] { signingKey = Self.hmac(signingKey, part) }
        let signature = Self.hex(Self.hmac(signingKey, stringToSign))
        headers.append(("authorization", "AWS4-HMAC-SHA256 Credential=\(credentials.accessKey)/\(scope), "
                        + "SignedHeaders=\(signedHeaders), Signature=\(signature)"))

        let scheme = location.endpoint.scheme ?? "https"
        let url = "\(scheme)://\(authority)\(canonicalURI)" + (canonicalQuery.isEmpty ? "" : "?" + canonicalQuery)
        return (url, headers.filter { $0.0 != "host" })
    }

    static func amzDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func hmac(_ key: Data, _ message: String) -> Data {
        ControlAgreement.hmacSHA256(key: key, message: Data(message.utf8))
    }

    static let unreserved = Set(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8))

    /// RFC 3986's unreserved characters stay; everything else is `%XX`, upper case.
    static func uriEncode(_ text: String, encodeSlash: Bool) -> String {
        var out = ""
        for byte in text.utf8 {
            if unreserved.contains(byte) || (!encodeSlash && byte == 0x2F) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}

/// One page of ListObjectsV2, read with string searches: the answer is flat, and a
/// parser would be the only XML in the program.
struct ListPage {
    var objects: [(key: String, etag: String)] = []
    var next: String?

    init(xml: String) {
        var rest = xml[...]
        while let open = rest.range(of: "<Contents>"), let close = rest.range(of: "</Contents>", range: open.upperBound..<rest.endIndex) {
            let item = rest[open.upperBound..<close.lowerBound]
            if let key = Self.value("Key", in: item), let etag = Self.value("ETag", in: item) {
                objects.append((Self.unescape(key), Self.unescape(etag)))
            }
            rest = rest[close.upperBound...]
        }
        if Self.value("IsTruncated", in: xml[...]) == "true" {
            next = Self.value("NextContinuationToken", in: xml[...]).map(Self.unescape)
        }
    }

    static func value(_ tag: String, in text: Substring) -> String? {
        guard let open = text.range(of: "<\(tag)>"), let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[open.upperBound..<close.lowerBound])
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#34;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
    }
}
