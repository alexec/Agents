// Say whether a TestFlight upload has been processed (#914): the iOS and the macOS build of
// one version and build number on the Universal record (Loops, Apple ID 6817621595), through
// the App Store Connect API. It reads only.
//
//   swift scripts/asc-builds.swift 0.3.0 57             each platform's state, now
//   swift scripts/asc-builds.swift 0.3.0 57 --wait 45   until both are VALID, for up to 45 minutes
//
// It exits 0 when both are VALID, 1 when one is INVALID or FAILED or the wait runs out, and
// 2 on a usage or key problem. The key is ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH, as for
// notarytool; without them, ~/.private_keys/asc.env and the AuthKey_<id>.p8 beside it.
import CryptoKit
import Foundation

let appID = "6817621595"
let platforms = ["IOS", "MAC_OS"]

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
guard args.count == 2 else { fail("usage: asc-builds.swift VERSION BUILD [--wait MINUTES]") }
let (version, build) = (args[0], args[1])

let env = ProcessInfo.processInfo.environment
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

/// Each platform's processing state, e.g. ["IOS": "VALID"]; a platform not there yet is absent.
func states() async throws -> [String: String] {
    var url = URLComponents(string: "https://api.appstoreconnect.apple.com/v1/builds")!
    url.queryItems = [
        .init(name: "filter[app]", value: appID),
        .init(name: "filter[version]", value: build),
        .init(name: "filter[preReleaseVersion.version]", value: version),
        .init(name: "include", value: "preReleaseVersion"),
        .init(name: "fields[builds]", value: "version,processingState,preReleaseVersion"),
        .init(name: "fields[preReleaseVersions]", value: "platform,version"),
    ]
    var request = URLRequest(url: url.url!)
    request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { fail("App Store Connect said \(status): \(String(decoding: data, as: UTF8.self))") }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    var platformOf: [String: String] = [:]
    for item in json["included"] as? [[String: Any]] ?? [] {
        if let id = item["id"] as? String,
           let platform = (item["attributes"] as? [String: Any])?["platform"] as? String {
            platformOf[id] = platform
        }
    }
    var result: [String: String] = [:]
    for item in json["data"] as? [[String: Any]] ?? [] {
        let state = (item["attributes"] as? [String: Any])?["processingState"] as? String ?? "?"
        let relation = (item["relationships"] as? [String: Any])?["preReleaseVersion"] as? [String: Any]
        if let id = (relation?["data"] as? [String: Any])?["id"] as? String, let platform = platformOf[id] {
            result[platform] = state
        }
    }
    return result
}

let deadline = Date().addingTimeInterval(waitMinutes * 60)
while true {
    let now = try await states()
    let line = platforms.map { "\($0) \(now[$0] ?? "not uploaded")" }.joined(separator: ", ")
    print("\(version) (\(build)): \(line)")
    if platforms.allSatisfy({ now[$0] == "VALID" }) { exit(0) }
    if now.values.contains(where: { $0 == "INVALID" || $0 == "FAILED" }) { exit(1) }
    if Date() >= deadline { exit(1) }
    try await Task.sleep(for: .seconds(60))
}
