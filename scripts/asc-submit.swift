// Submit a version for App Review (#3657): the iOS version of the App Store record (Loops, Apple
// ID 6817621595; iPhone and iPad only since #4229), with the newest processed (VALID) build of
// that version, through the App Store Connect API. app-store.yml runs it only after a person approved the
// `app-store` environment's gate; it never runs on its own.
//
//   swift scripts/asc-submit.swift 0.3.0             submit now, when the build is VALID
//   swift scripts/asc-submit.swift 0.3.0 --wait 60   wait for the build, for up to 60 minutes
//
// For each platform it finds or makes the App Store version (or renames the one still being
// prepared), sets its build, sets "What's New" to WHATS_NEW when given and App Store Connect
// takes it (a first version has none), adds the version to an open review submission (or a new
// one) and submits that. The last line it prints is the build number it submitted.
//
// It exits 0 when it is submitted, 1 when App Store Connect refuses or the wait runs out, and
// 2 on a usage or key problem. The key is ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH, as for
// asc-builds.swift; without them, ~/.private_keys/asc.env and the AuthKey_<id>.p8 beside it.
import CryptoKit
import Foundation

let appID = "6817621595"
let platforms = ["IOS"]

func fail(_ message: String, _ code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())
var waitMinutes = 0.0
if let i = args.firstIndex(of: "--wait") {
    guard i + 1 < args.count, let minutes = Double(args[i + 1]) else { fail("--wait needs minutes") }
    waitMinutes = minutes
    args.removeSubrange(i...(i + 1))
}
guard args.count == 1 else { fail("usage: asc-submit.swift VERSION [--wait MINUTES]") }
let version = args[0]

let env = ProcessInfo.processInfo.environment
let whatsNew = String((env["WHATS_NEW"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
var keyID = env["ASC_KEY_ID"] ?? ""
var issuerID = env["ASC_ISSUER_ID"] ?? ""
var keyPath = env["ASC_KEY_PATH"] ?? ""
let keys = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".private_keys")
if keyID.isEmpty || issuerID.isEmpty,
   let file = try? String(contentsOf: keys.appending(path: "asc.env"), encoding: .utf8) {
    for line in file.split(separator: "\n") {
        let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard pair.count == 2 else { continue }
        if pair[0] == "ASC_KEY_ID", keyID.isEmpty { keyID = pair[1] }
        if pair[0] == "ASC_ISSUER_ID", issuerID.isEmpty { issuerID = pair[1] }
    }
}
if keyPath.isEmpty { keyPath = keys.appending(path: "AuthKey_\(keyID).p8").path }
guard !keyID.isEmpty, !issuerID.isEmpty else { fail("No ASC_KEY_ID and ASC_ISSUER_ID, and no ~/.private_keys/asc.env") }
guard let pem = try? String(contentsOfFile: keyPath, encoding: .utf8),
      let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { fail("Cannot read the key at \(keyPath)") }

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

/// A token good for 15 minutes, made fresh for each request.
func token() throws -> String {
    let now = Int(Date().timeIntervalSince1970)
    let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
    let claims = try JSONSerialization.data(withJSONObject: [
        "iss": issuerID, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1",
    ] as [String: Any])
    let input = base64URL(header) + "." + base64URL(claims)
    let signature = try key.signature(for: Data(input.utf8))
    return input + "." + base64URL(signature.rawRepresentation)
}

typealias JSON = [String: Any]

/// One request; its status and its JSON. A status App Store Connect refuses fails, unless allowed.
@discardableResult
func call(_ method: String, _ path: String, _ query: [String: String] = [:], body: JSON? = nil,
          allow: Set<Int> = []) async throws -> (Int, JSON) {
    var url = URLComponents(string: "https://api.appstoreconnect.apple.com" + path)!
    if !query.isEmpty { url.queryItems = query.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) } }
    var request = URLRequest(url: url.url!)
    request.httpMethod = method
    request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["data": body])
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) || allow.contains(status) else {
        fail("\(method) \(path): App Store Connect said \(status): \(String(decoding: data, as: UTF8.self))", 1)
    }
    return (status, (try? JSONSerialization.jsonObject(with: data) as? JSON) ?? [:])
}

func items(_ json: JSON) -> [JSON] { json["data"] as? [JSON] ?? [] }
func id(_ item: JSON?) -> String? { item?["id"] as? String }
func attribute(_ item: JSON, _ name: String) -> String? { (item["attributes"] as? JSON)?[name] as? String }
func ref(_ type: String, _ id: String) -> JSON { ["data": ["type": type, "id": id]] }

/// The newest VALID build of this version on a platform: its id and its build number.
func build(_ platform: String) async throws -> (id: String, number: String)? {
    let (_, json) = try await call("GET", "/v1/builds", [
        "filter[app]": appID, "filter[preReleaseVersion.version]": version,
        "filter[preReleaseVersion.platform]": platform, "filter[processingState]": "VALID",
        "sort": "-uploadedDate", "limit": "1", "fields[builds]": "version",
    ])
    guard let first = items(json).first, let id = id(first), let number = attribute(first, "version") else { return nil }
    return (id, number)
}

/// The App Store version for this version string on a platform: the one there is, the one still
/// being prepared renamed to it (a record has one editable version), or a new one.
func appStoreVersion(_ platform: String) async throws -> String {
    let (_, same) = try await call("GET", "/v1/apps/\(appID)/appStoreVersions",
                                   ["filter[platform]": platform, "filter[versionString]": version])
    if let found = id(items(same).first) { return found }
    let (_, editable) = try await call("GET", "/v1/apps/\(appID)/appStoreVersions",
                                       ["filter[platform]": platform, "filter[appVersionState]": "PREPARE_FOR_SUBMISSION"])
    if let found = id(items(editable).first) {
        try await call("PATCH", "/v1/appStoreVersions/\(found)",
                       body: ["type": "appStoreVersions", "id": found, "attributes": ["versionString": version]])
        return found
    }
    let (_, made) = try await call("POST", "/v1/appStoreVersions", body: [
        "type": "appStoreVersions", "attributes": ["platform": platform, "versionString": version],
        "relationships": ["app": ref("apps", appID)],
    ])
    guard let made = id(made["data"] as? JSON) else { fail("App Store Connect made no \(platform) version \(version)", 1) }
    return made
}

/// "What's New" on each of the version's localizations. A first version takes none (409): say so.
func setWhatsNew(_ versionID: String, _ platform: String) async throws {
    guard !whatsNew.isEmpty else { return }
    let (_, json) = try await call("GET", "/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations")
    for localization in items(json) {
        guard let lid = id(localization) else { continue }
        let (status, _) = try await call("PATCH", "/v1/appStoreVersionLocalizations/\(lid)", body: [
            "type": "appStoreVersionLocalizations", "id": lid, "attributes": ["whatsNew": whatsNew],
        ], allow: [409])
        if status == 409 { print("\(platform): App Store Connect takes no What's New for this version"); return }
    }
}

/// Add the version to an open review submission on the platform, or a new one, and submit it.
func submit(_ versionID: String, _ platform: String) async throws -> String {
    let (_, open) = try await call("GET", "/v1/reviewSubmissions",
                                   ["filter[app]": appID, "filter[platform]": platform, "filter[state]": "READY_FOR_REVIEW"])
    var submission = id(items(open).first)
    if submission == nil {
        let (_, made) = try await call("POST", "/v1/reviewSubmissions", body: [
            "type": "reviewSubmissions", "attributes": ["platform": platform],
            "relationships": ["app": ref("apps", appID)],
        ])
        submission = id(made["data"] as? JSON)
    }
    guard let submission else { fail("App Store Connect made no \(platform) review submission", 1) }
    // 409: the version is in it already, from a run that stopped before it submitted.
    try await call("POST", "/v1/reviewSubmissionItems", body: [
        "type": "reviewSubmissionItems",
        "relationships": ["reviewSubmission": ref("reviewSubmissions", submission),
                          "appStoreVersion": ref("appStoreVersions", versionID)],
    ], allow: [409])
    try await call("PATCH", "/v1/reviewSubmissions/\(submission)", body: [
        "type": "reviewSubmissions", "id": submission, "attributes": ["submitted": true],
    ])
    return submission
}

let deadline = Date().addingTimeInterval(waitMinutes * 60)
var builds: [String: (id: String, number: String)] = [:]
while true {
    for platform in platforms where builds[platform] == nil {
        builds[platform] = try await build(platform)
    }
    print("\(version): " + platforms.map { "\($0) \(builds[$0].map { "build \($0.number) VALID" } ?? "no VALID build")" }
        .joined(separator: ", "))
    if builds.count == platforms.count { break }
    if Date() >= deadline { exit(1) }
    try await Task.sleep(for: .seconds(60))
}

for platform in platforms {
    let build = builds[platform]!
    let versionID = try await appStoreVersion(platform)
    try await call("PATCH", "/v1/appStoreVersions/\(versionID)/relationships/build", body: ["type": "builds", "id": build.id])
    try await setWhatsNew(versionID, platform)
    let submission = try await submit(versionID, platform)
    print("\(platform) \(version) (\(build.number)): submitted for App Review, review submission \(submission)")
}
print(builds["IOS"]!.number)
