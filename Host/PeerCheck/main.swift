// agents-peer (#1138): the Go agentsd's code-signature check on daemon.sock's callers.
// The Security framework needs cgo, so the Go host asks this helper, which runs beside it
// in Agents Host's Helpers for as long as the host does.
//
// It begins with one line: `team <ID>`, the team it is signed by, or `unsigned`, and then
// stops. After `team`, it reads one audit token a line, as 64 hex digits (the kernel's 32
// bytes, as LOCAL_PEERTOKEN gives them), and answers that process's role on a line:
// control, agent, hostApp, window or stranger. These are RolePolicy.signedRoles and
// CallerSignature's requirement (AgentsKit), which the Swift agentsd checks for itself.
//
// `agents-peer container <group>` instead makes the app group's container and says its path
// (#1118): macOS refuses a plain mkdir there, and Go cannot ask for it without cgo.
import Foundation
import Security

/// Who gets what, each signed by this helper's team, tried in order. Exact identifiers
/// only: anything not named here, of any team, is a stranger.
let signedRoles: [(role: String, identifiers: [String])] = [
    ("control", ["com.alexecollins.agents", "com.alexecollins.agents.bridge"]),
    ("agent", ["agentsd"]),
    ("hostApp", ["com.alexecollins.agents.host"]),
    // The App Store window (Debug and Live are `.store`, the App Store's is the Remote's id):
    // it may prove its key on the local socket (#1118), and is a stranger on daemon.sock.
    ("window", ["com.alexecollins.agents.store", "com.alexecollins.agents.remote"]),
]

func ownTeam() -> String? {
    var me: SecCode?
    guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
    var onDisk: SecStaticCode?
    guard SecCodeCopyStaticCode(me, [], &onDisk) == errSecSuccess, let onDisk else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(onDisk, SecCSFlags(rawValue: kSecCSSigningInformation),
                                        &info) == errSecSuccess,
          let info = info as? [String: Any] else { return nil }
    return info[kSecCodeInfoTeamIdentifier as String] as? String
}

/// One of `identifiers`, signed through Apple by `team`.
func requirement(team: String, identifiers: [String]) -> SecRequirement? {
    let names = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
    let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (\(names))"
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
    return requirement
}

/// The 32 bytes of an audit token, from 64 hex digits.
func token(_ hex: Substring) -> Data? {
    guard hex.count == 64 else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(32)
    var at = hex.startIndex
    while at < hex.endIndex {
        let next = hex.index(at, offsetBy: 2)
        guard let byte = UInt8(hex[at..<next], radix: 16) else { return nil }
        bytes.append(byte)
        at = next
    }
    return Data(bytes)
}

func role(of audit: Data, _ rules: [(String, SecRequirement)]) -> String {
    var code: SecCode?
    let attributes = [kSecGuestAttributeAudit: audit] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
        return "stranger"
    }
    return rules.first { SecCodeCheckValidity(code, [], $0.1) == errSecSuccess }?.0 ?? "stranger"
}

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "container" {
    guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: arguments[2]) else {
        FileHandle.standardError.write(Data("no container for \(arguments[2]): not in this helper's entitlements\n".utf8))
        exit(1)
    }
    print(url.path)
    exit(0)
}
guard let team = ownTeam() else {
    print("unsigned")
    exit(0)
}
let rules = signedRoles.compactMap { rule in
    requirement(team: team, identifiers: rule.identifiers).map { (rule.role, $0) }
}
print("team \(team)")
while let line = readLine() {
    let hex = line.trimmingCharacters(in: .whitespaces)
    guard let audit = token(Substring(hex)) else {
        print("stranger")
        continue
    }
    print(role(of: audit, rules))
}
