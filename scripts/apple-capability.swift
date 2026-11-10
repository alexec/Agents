// Turn on an App ID capability and make its provisioning profiles again (#4284), through the
// App Store Connect API. Run it with scripts/apple-capability.sh, whose header says how and when.
//
//   swift scripts/apple-capability.swift BUNDLE-ID CAPABILITY [--dry-run] [--platform P]
//                                        [--name NAME] [--profile TYPE:NAME]…
//
// It reads first and changes nothing until it has printed its plan and read "yes" on its input.
import CryptoKit
import Foundation

typealias JSON = [String: Any]

func fail(_ message: String, _ code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = "usage: apple-capability.sh BUNDLE-ID CAPABILITY [--dry-run] [--platform mac|ios|universal] "
    + "[--name NAME] [--profile TYPE:NAME]…"

let capabilityNames = [
    "sign-in-with-apple": "APPLE_ID_AUTH", "push": "PUSH_NOTIFICATIONS", "app-groups": "APP_GROUPS",
    "associated-domains": "ASSOCIATED_DOMAINS", "icloud": "ICLOUD",
]
let platformNames = ["mac": "MAC_OS", "ios": "IOS", "universal": "UNIVERSAL"]

/// The certificate types each profile type can be signed with, the first one found wins, and
/// whether it lists devices.
let profileTypes: [String: (certificates: [String], devices: Bool)] = [
    "MAC_APP_DIRECT": (["DEVELOPER_ID_APPLICATION_G2", "DEVELOPER_ID_APPLICATION"], false),
    "MAC_APP_DEVELOPMENT": (["DEVELOPMENT", "MAC_APP_DEVELOPMENT"], true),
    "MAC_APP_STORE": (["DISTRIBUTION", "MAC_APP_DISTRIBUTION"], false),
    "IOS_APP_DEVELOPMENT": (["DEVELOPMENT", "IOS_DEVELOPMENT"], true),
    "IOS_APP_ADHOC": (["DISTRIBUTION", "IOS_DISTRIBUTION"], true),
    "IOS_APP_STORE": (["DISTRIBUTION", "IOS_DISTRIBUTION"], false),
]

// MARK: Arguments

var args = Array(CommandLine.arguments.dropFirst())
var dryRun = false
var platform = "MAC_OS"
var appName: String?
var wantedProfiles: [(type: String, name: String)] = []
var positional: [String] = []
while !args.isEmpty {
    let arg = args.removeFirst()
    func value() -> String {
        guard !args.isEmpty else { fail("\(arg) needs a value\n\(usage)") }
        return args.removeFirst()
    }
    switch arg {
    case "--dry-run": dryRun = true
    case "--platform":
        let p = value()
        guard let type = platformNames[p] else { fail("--platform is mac, ios or universal, not \(p)") }
        platform = type
    case "--name": appName = value()
    case "--profile":
        let spec = value()
        guard let colon = spec.firstIndex(of: ":"), case let type = String(spec[..<colon]),
              profileTypes[type] != nil, !spec[spec.index(after: colon)...].isEmpty else {
            fail("--profile is TYPE:NAME, TYPE one of \(profileTypes.keys.sorted().joined(separator: ", ")); not \(spec)")
        }
        wantedProfiles.append((type, String(spec[spec.index(after: colon)...])))
    case _ where arg.hasPrefix("-"): fail("unknown option \(arg)\n\(usage)")
    default: positional.append(arg)
    }
}
guard positional.count == 2 else { fail(usage) }
let bundleID = positional[0]
guard bundleID.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil else {
    fail("\(bundleID) is not a bundle id (letters, digits and hyphens between dots, no dot at the end)")
}
let capability = capabilityNames[positional[1]] ?? positional[1]
guard capability.range(of: #"^[A-Z][A-Z0-9_]+$"#, options: .regularExpression) != nil else {
    fail("\(positional[1]) is not a capability: give App Store Connect's capabilityType, or one of "
        + capabilityNames.keys.sorted().joined(separator: ", "))
}
if ProcessInfo.processInfo.environment["APPLE_CAPABILITY_PARSE_ONLY"] == "1" {
    // For a test of the parsing: what it understood, and no request.
    print("bundle \(bundleID) capability \(capability) platform \(platform) name \(appName ?? bundleID) "
        + "dry-run \(dryRun) profiles \(wantedProfiles.map { "\($0.type):\($0.name)" })")
    exit(0)
}

// MARK: The key, as asc-builds.swift reads it

let env = ProcessInfo.processInfo.environment
var keyID = env["ASC_KEY_ID"] ?? ""
var issuerID = env["ASC_ISSUER_ID"] ?? ""
var keyPath = env["ASC_KEY_PATH"] ?? ""
let home = FileManager.default.homeDirectoryForCurrentUser
let keys = home.appending(path: ".private_keys")
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

// MARK: Requests

/// One request; its JSON. A status App Store Connect refuses fails.
@discardableResult
func call(_ method: String, _ path: String, _ query: [String: String] = [:], body: JSON? = nil) async throws -> JSON {
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
    guard (200..<300).contains(status) else {
        fail("\(method) \(path): App Store Connect said \(status): \(String(decoding: data, as: UTF8.self))", 1)
    }
    return (try? JSONSerialization.jsonObject(with: data) as? JSON) ?? [:]
}

func items(_ json: JSON) -> [JSON] { json["data"] as? [JSON] ?? [] }
func id(_ item: JSON) -> String { item["id"] as? String ?? "" }
func attribute(_ item: JSON, _ name: String) -> String? { (item["attributes"] as? JSON)?[name] as? String }
/// Whether a certificate has not expired yet; a date it cannot read counts as not expired.
func notExpired(_ certificate: JSON) -> Bool {
    guard let text = attribute(certificate, "expirationDate") else { return true }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    return (date ?? .distantFuture) > Date()
}
func ref(_ type: String, _ id: String) -> JSON { ["data": ["type": type, "id": id]] }
func refs(_ type: String, _ ids: [String]) -> JSON { ["data": ids.map { ["type": type, "id": $0] }] }

/// The certificates of the first type in `types` that has one not expired yet.
func certificates(_ types: [String]) async throws -> [JSON] {
    for type in types {
        let found = items(try await call("GET", "/v1/certificates", ["filter[certificateType]": type, "limit": "200"]))
            .filter(notExpired)
        if !found.isEmpty { return found }
    }
    return []
}

/// This Mac's provisioning UDID, as the developer site lists Macs.
func thisMacUDID() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    process.arguments = ["SPHardwareDataType"]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return nil }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    for line in output.split(separator: "\n") where line.contains("Provisioning UDID:") {
        return line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) }
    }
    return nil
}

/// The registered devices a new profile of this type lists: this Mac for a Mac one, every
/// enabled iPhone and iPad for an iOS one.
func devices(for type: String) async throws -> [JSON] {
    if type.hasPrefix("MAC_") {
        guard let udid = thisMacUDID() else { fail("Cannot read this Mac's provisioning UDID", 1) }
        let found = items(try await call("GET", "/v1/devices", ["filter[udid]": udid, "filter[platform]": "MAC_OS"]))
        guard !found.isEmpty else { fail("This Mac (\(udid)) is not a registered device: register it on the developer site", 1) }
        return found
    }
    return items(try await call("GET", "/v1/devices", ["filter[platform]": "IOS", "filter[status]": "ENABLED", "limit": "200"]))
}

func names(_ list: [JSON], _ name: String) -> String {
    list.map { attribute($0, name) ?? id($0) }.joined(separator: ", ")
}

// MARK: Plan

/// A profile to make: from an old one (deleted first) or new.
struct NewProfile {
    var name: String
    var type: String
    var certificates: [JSON]
    var devices: [JSON]
    var old: JSON?
}

let bundles = items(try await call("GET", "/v1/bundleIds", [
    "filter[identifier]": bundleID, "limit": "200",
])).filter { attribute($0, "identifier") == bundleID }
let bundle = bundles.first
var capabilityOn = false
var existing: [JSON] = []
if let bundle {
    capabilityOn = items(try await call("GET", "/v1/bundleIds/\(id(bundle))/bundleIdCapabilities"))
        .contains { attribute($0, "capabilityType") == capability }
    existing = items(try await call("GET", "/v1/bundleIds/\(id(bundle))/profiles", ["limit": "200"]))
}

var plan: [String] = []
if bundle == nil { plan.append("register the App ID \(bundleID) (\(appName ?? bundleID), \(platform))") }
if !capabilityOn { plan.append("turn on \(capability) for \(bundleID)") }

// Turning a capability on makes every profile of the App ID invalid (#2507), and the API cannot
// regenerate one: delete it and make it again with the same name, type, certificates and devices.
var toMake: [NewProfile] = []
for profile in existing {
    let type = attribute(profile, "profileType") ?? ""
    let state = attribute(profile, "profileState") ?? ""
    guard state == "INVALID" || !capabilityOn else { continue }
    let certs = items(try await call("GET", "/v1/profiles/\(id(profile))/certificates", ["limit": "200"]))
        .filter(notExpired)
    let devs = items(try await call("GET", "/v1/profiles/\(id(profile))/devices", ["limit": "200"]))
    guard !certs.isEmpty else {
        print("skip \(attribute(profile, "name") ?? id(profile)) (\(type)): its certificates have all expired")
        continue
    }
    toMake.append(.init(name: attribute(profile, "name") ?? bundleID, type: type, certificates: certs, devices: devs, old: profile))
}
var toInstall: [JSON] = []
for (type, name) in wantedProfiles {
    let same = existing.first { attribute($0, "name") == name && attribute($0, "profileType") == type }
    if let same, toMake.contains(where: { $0.old.map(id) == id(same) }) { continue }
    if let same, attribute(same, "profileState") == "ACTIVE" { toInstall.append(same); continue }
    let certs = try await certificates(profileTypes[type]!.certificates)
    guard !certs.isEmpty else { fail("No certificate for a \(type) profile: make one on the developer site", 1) }
    let devs = profileTypes[type]!.devices ? try await devices(for: type) : []
    toMake.append(.init(name: name, type: type, certificates: certs, devices: devs, old: same))
}
for profile in toMake {
    if let old = profile.old { plan.append("delete the profile \(profile.name) (\(attribute(old, "profileState") ?? "?"), \(id(old)))") }
    var line = "make the \(profile.type) profile \(profile.name) with \(names(profile.certificates, "name"))"
    if !profile.devices.isEmpty { line += ", devices \(names(profile.devices, "name"))" }
    plan.append(line + ", and install it")
}

let installDirs = [
    home.appending(path: "Library/Developer/Xcode/UserData/Provisioning Profiles"),
    home.appending(path: "Library/MobileDevice/Provisioning Profiles"),
]
func file(_ uuid: String, _ type: String, in dir: URL) -> URL {
    dir.appending(path: uuid + (type.hasPrefix("MAC_") ? ".provisionprofile" : ".mobileprovision"))
}
for profile in toInstall {
    let uuid = attribute(profile, "uuid") ?? ""
    if !FileManager.default.fileExists(atPath: file(uuid, attribute(profile, "profileType") ?? "", in: installDirs[0]).path) {
        plan.append("install the profile \(attribute(profile, "name") ?? uuid) (\(uuid))")
    }
}

guard !plan.isEmpty else {
    print("Nothing to change: \(bundleID) has \(capability), and its profiles are valid and installed.")
    exit(0)
}
print("On the Apple Developer account, this would:")
for step in plan { print("  - \(step)") }
if dryRun { print("Dry run: nothing changed."); exit(0) }

print("Alex approves this change (a lane asks by a form first). Type yes to go on: ", terminator: "")
guard readLine()?.trimmingCharacters(in: .whitespaces) == "yes" else { print("\nNothing changed."); exit(1) }

// MARK: Change

/// Write a profile's content where Xcode reads it, and remove the file of the one it replaces.
func install(_ profile: JSON, replacing old: JSON? = nil) throws {
    let type = attribute(profile, "profileType") ?? ""
    guard let content = attribute(profile, "profileContent"), let data = Data(base64Encoded: content),
          let uuid = attribute(profile, "uuid") else { fail("The profile \(id(profile)) came with no content", 1) }
    for (n, dir) in installDirs.enumerated() where n == 0 || FileManager.default.fileExists(atPath: dir.path) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let oldUUID = old.flatMap({ attribute($0, "uuid") }) {
            try? FileManager.default.removeItem(at: file(oldUUID, type, in: dir))
        }
        try data.write(to: file(uuid, type, in: dir))
    }
    print("installed \(attribute(profile, "name") ?? uuid) (\(uuid))")
}

var bundleRef = bundle.map(id) ?? ""
if bundle == nil {
    let made = try await call("POST", "/v1/bundleIds", body: [
        "type": "bundleIds", "attributes": ["identifier": bundleID, "name": appName ?? bundleID, "platform": platform],
    ])
    bundleRef = (made["data"] as? JSON).map(id) ?? ""
    print("registered \(bundleID) (\(bundleRef))")
}
if !capabilityOn {
    var attributes: JSON = ["capabilityType": capability]
    if capability == "APPLE_ID_AUTH" {
        attributes["settings"] = [["key": "APPLE_ID_AUTH_APP_CONSENT", "options": [["key": "PRIMARY_APP_CONSENT"]]]]
    }
    try await call("POST", "/v1/bundleIdCapabilities", body: [
        "type": "bundleIdCapabilities", "attributes": attributes,
        "relationships": ["bundleId": ref("bundleIds", bundleRef)],
    ])
    print("turned on \(capability)")
}
for profile in toMake {
    if let old = profile.old {
        try await call("DELETE", "/v1/profiles/\(id(old))")
        print("deleted \(profile.name) (\(id(old)))")
    }
    var relationships: JSON = [
        "bundleId": ref("bundleIds", bundleRef),
        "certificates": refs("certificates", profile.certificates.map(id)),
    ]
    if !profile.devices.isEmpty { relationships["devices"] = refs("devices", profile.devices.map(id)) }
    let made = try await call("POST", "/v1/profiles", body: [
        "type": "profiles", "attributes": ["name": profile.name, "profileType": profile.type],
        "relationships": relationships,
    ])
    try install(made["data"] as? JSON ?? [:], replacing: profile.old)
}
for profile in toInstall {
    // The list leaves out the content; read the profile itself.
    try install(try await call("GET", "/v1/profiles/\(id(profile))")["data"] as? JSON ?? [:])
}
print("Done.")
