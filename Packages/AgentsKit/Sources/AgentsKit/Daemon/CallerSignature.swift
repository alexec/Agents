import AgentsKitCore
import Foundation
#if canImport(Security)
import Security
#endif

/// Which role a connection gets, from the code signature of the process that made it.
///
/// Every process of this account can reach the socket, so a file mode or a secret on
/// disk tells nothing apart: an agent's shell can read whatever the app can. What it
/// cannot do is be the app. The kernel names the process on the other end by audit
/// token, which a caller cannot forge, and the signature on that process says which
/// program it is and whose. The app and the bridge are control; this daemon's own
/// binary, run as a runtime's MCP helper, is an agent; anything else is a stranger.
public struct RolePolicy: Sendable {
    public let role: @Sendable (_ fd: Int32) -> ConnectionRole
    /// Said once in the log, so which door is in place is never a guess.
    public let summary: String

    public init(summary: String, role: @escaping @Sendable (_ fd: Int32) -> ConnectionRole) {
        self.summary = summary
        self.role = role
    }

    /// Everything to everyone this account runs: what the socket was before roles.
    public static let open = RolePolicy(summary: "every process of this account may call everything") { _ in .control }

    /// The bundle identifiers that are control. The helper is the daemon's own binary.
    public static let controlIdentifiers = ["com.alexecollins.agents", "com.alexecollins.agents.bridge"]
    public static let helperIdentifier = "agentsd"

    /// The policy for a daemon at `locations`.
    ///
    /// Roles need signatures to tell programs apart, so a daemon that is not signed by
    /// a team — `swift build`, the tests — cannot hold them, and on Linux there are no
    /// signatures at all; there the uid check and the private root are the door, and an
    /// agent on a server can do what that account can. A scratch root is open unless
    /// `AGENTS_ENFORCE_ROLES` is set: a walk drives its daemon from a shell, and nothing
    /// on a scratch root is anybody's real work.
    public static func forDaemon(at locations: StoreLocations,
                                 environment: [String: String] = ProcessInfo.processInfo.environment) -> RolePolicy {
        #if canImport(Security)
        guard let team = CallerSignature.ownTeam else {
            return RolePolicy(summary: "not signed by a team, so " + open.summary, role: open.role)
        }
        if !locations.isStandard && environment["AGENTS_ENFORCE_ROLES"] == nil {
            return RolePolicy(summary: "a scratch root, so " + open.summary, role: open.role)
        }
        return signatures(team: team)
        #else
        return open
        #endif
    }

    #if canImport(Security)
    /// Control for the app and the bridge, agent for the helper, all signed by `team`.
    public static func signatures(team: String) -> RolePolicy {
        let wanted = CallerSignature.Requirements(
            control: CallerSignature.requirement(team: team, identifiers: controlIdentifiers),
            helper: CallerSignature.requirement(team: team, identifiers: [helperIdentifier]))
        return RolePolicy(summary: "roles by code signature, team \(team)") { fd in
            guard let code = CallerSignature.code(of: fd) else { return .stranger }
            if let control = wanted.control, CallerSignature.satisfies(code, control) { return .control }
            if let helper = wanted.helper, CallerSignature.satisfies(code, helper) { return .agent }
            return .stranger
        }
    }
    #endif
}

#if canImport(Security)
enum CallerSignature {
    /// Compiled once and only read after: a requirement is an immutable CF object.
    struct Requirements: @unchecked Sendable {
        let control: SecRequirement?
        let helper: SecRequirement?
    }

    /// The team this process is signed by, or nil when it is not.
    static let ownTeam: String? = {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var onDisk: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &onDisk) == errSecSuccess, let onDisk else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(onDisk, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// One of `identifiers`, signed through Apple by `team`. A development certificate
    /// and a Developer ID one both carry the team as the leaf's organisational unit.
    static func requirement(team: String, identifiers: [String]) -> SecRequirement? {
        let names = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and (\(names))"
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// The running code on the other end of `fd`, by the audit token the kernel keeps
    /// for the connection. Nil if it has gone or the kernel would not say.
    static func code(of fd: Int32) -> SecCode? {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else { return nil }
        let data = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: data] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
        return code
    }

    static func satisfies(_ code: SecCode, _ requirement: SecRequirement) -> Bool {
        SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
#endif
