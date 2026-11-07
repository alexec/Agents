// The app's App Store Connect calls, with the team API key:
//
//   swift scripts/asc.swift register                   register the bundle id (setup.yml)
//   swift scripts/asc.swift submit 1.2.0 --wait 110    submit the version for App Review when its
//                                                      build is processed (app-store.yml)
//
// submit finds or makes the App Store version (or renames the one still being prepared), sets
// its build to the newest processed (VALID) one, sets "What's New" to WHATS_NEW when App Store
// Connect takes it (a first version has none), adds the version to an open review submission
// (or a new one) and submits that. The last line it prints is the build number it submitted.
//
// It exits 0 when it is done, 1 when App Store Connect refuses or the wait runs out, and 2 on a
// usage or key problem. The key is ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file).
import CryptoKit
import Foundation

let bundleID = "__BUNDLE_ID__"
let appName = "__APP_NAME__"

func fail(_ message: String, _ code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = "usage: asc.swift register | asc.swift submit VERSION [--wait MINUTES]"
var args = Array(CommandLine.arguments.dropFirst())
var waitMinutes = 0.0
if let i = args.firstIndex(of: "--wait") {
    guard i + 1 < args.count, let minutes = Double(args[i + 1]) else { fail("--wait needs minutes") }
    waitMinutes = minutes
    args.removeSubrange(i...(i + 1))
}
guard let command = args.first else { fail(usage) }

let env = ProcessInfo.processInfo.environment
let keyID = env["ASC_KEY_ID"] ?? ""
let issuerID = env["ASC_ISSUER_ID"] ?? ""
let keyPath = env["ASC_KEY_PATH"] ?? ""
guard !keyID.isEmpty, !issuerID.isEmpty, !keyPath.isEmpty else { fail("Set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH") }
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

// MARK: register

func register() async throws {
    // The filter also matches other bundle ids that start with this one.
    let (_, json) = try await call("GET", "/v1/bundleIds", ["filter[identifier]": bundleID, "limit": "200"])
    if items(json).contains(where: { attribute($0, "identifier") == bundleID }) {
        print("\(bundleID) is registered already")
        return
    }
    // A bundle id's name takes letters, digits and spaces only.
    let name = String(appName.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " })
    try await call("POST", "/v1/bundleIds", body: [
        "type": "bundleIds",
        "attributes": ["identifier": bundleID, "name": name.isEmpty ? "App" : name, "platform": "IOS"],
    ])
    print("\(bundleID) is registered")
}

// MARK: submit

/// The app's record in App Store Connect. A person makes it, as the API has no call for that.
func appID() async throws -> String {
    let (_, json) = try await call("GET", "/v1/apps", ["filter[bundleId]": bundleID, "limit": "1"])
    guard let found = id(items(json).first) else {
        fail("App Store Connect has no app with the bundle id \(bundleID): make its record first", 1)
    }
    return found
}

/// The newest VALID build of this version: its id and its build number.
func build(_ app: String, _ version: String) async throws -> (id: String, number: String)? {
    let (_, json) = try await call("GET", "/v1/builds", [
        "filter[app]": app, "filter[preReleaseVersion.version]": version,
        "filter[preReleaseVersion.platform]": "IOS", "filter[processingState]": "VALID",
        "sort": "-uploadedDate", "limit": "1", "fields[builds]": "version",
    ])
    guard let first = items(json).first, let id = id(first), let number = attribute(first, "version") else { return nil }
    return (id, number)
}

/// The App Store version for this version string: the one there is, the one still being
/// prepared renamed to it (a record has one editable version), or a new one.
func appStoreVersion(_ app: String, _ version: String) async throws -> String {
    let (_, same) = try await call("GET", "/v1/apps/\(app)/appStoreVersions",
                                   ["filter[platform]": "IOS", "filter[versionString]": version])
    if let found = id(items(same).first) { return found }
    let (_, editable) = try await call("GET", "/v1/apps/\(app)/appStoreVersions",
                                       ["filter[platform]": "IOS", "filter[appVersionState]": "PREPARE_FOR_SUBMISSION"])
    if let found = id(items(editable).first) {
        try await call("PATCH", "/v1/appStoreVersions/\(found)",
                       body: ["type": "appStoreVersions", "id": found, "attributes": ["versionString": version]])
        return found
    }
    let (_, made) = try await call("POST", "/v1/appStoreVersions", body: [
        "type": "appStoreVersions", "attributes": ["platform": "IOS", "versionString": version],
        "relationships": ["app": ref("apps", app)],
    ])
    guard let made = id(made["data"] as? JSON) else { fail("App Store Connect made no version \(version)", 1) }
    return made
}

/// "What's New" on each of the version's localizations. A first version takes none (409): say so.
func setWhatsNew(_ versionID: String) async throws {
    let whatsNew = String((env["WHATS_NEW"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
    guard !whatsNew.isEmpty else { return }
    let (_, json) = try await call("GET", "/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations")
    for localization in items(json) {
        guard let lid = id(localization) else { continue }
        let (status, _) = try await call("PATCH", "/v1/appStoreVersionLocalizations/\(lid)", body: [
            "type": "appStoreVersionLocalizations", "id": lid, "attributes": ["whatsNew": whatsNew],
        ], allow: [409])
        if status == 409 { print("App Store Connect takes no What's New for this version"); return }
    }
}

/// Add the version to an open review submission, or a new one, and submit it.
func submit(_ app: String, _ versionID: String) async throws -> String {
    let (_, open) = try await call("GET", "/v1/reviewSubmissions",
                                   ["filter[app]": app, "filter[platform]": "IOS", "filter[state]": "READY_FOR_REVIEW"])
    var submission = id(items(open).first)
    if submission == nil {
        let (_, made) = try await call("POST", "/v1/reviewSubmissions", body: [
            "type": "reviewSubmissions", "attributes": ["platform": "IOS"],
            "relationships": ["app": ref("apps", app)],
        ])
        submission = id(made["data"] as? JSON)
    }
    guard let submission else { fail("App Store Connect made no review submission", 1) }
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

func submitVersion(_ version: String) async throws {
    let app = try await appID()
    let deadline = Date().addingTimeInterval(waitMinutes * 60)
    var found = try await build(app, version)
    while found == nil {
        print("\(version): no VALID build yet")
        if Date() >= deadline { exit(1) }
        try await Task.sleep(for: .seconds(60))
        found = try await build(app, version)
    }
    let build = found!
    let versionID = try await appStoreVersion(app, version)
    try await call("PATCH", "/v1/appStoreVersions/\(versionID)/relationships/build", body: ["type": "builds", "id": build.id])
    try await setWhatsNew(versionID)
    let submission = try await submit(app, versionID)
    print("\(version) (\(build.number)): submitted for App Review, review submission \(submission)")
    print(build.number)
}

switch (command, args.count) {
case ("register", 1): try await register()
case ("submit", 2): try await submitVersion(args[1])
default: fail(usage)
}
