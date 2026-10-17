import Darwin
import Foundation
import Security

// agents-mac (#1138): what the Go agentsd asks of macOS that Go cannot do without cgo.
// Agents Host carries it in Contents/Helpers, beside agentsd-go, signed by the same team.
//
//   agents-mac peers   on stdin, a socket: each message is one byte with a descriptor
//                      (SCM_RIGHTS), a connection on daemon.sock. It answers a line:
//                      "other-user", "stranger", or "signed <identifier>" for code signed
//                      through Apple by this helper's team (CallerSignature.swift). Its
//                      first line is "team <id>", or "team -" when it is not signed by one.

/// The team this process is signed by, or nil when it is not (CallerSignature.ownTeam).
func ownTeam() -> String? {
    var me: SecCode?
    guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
    var onDisk: SecStaticCode?
    guard SecCodeCopyStaticCode(me, [], &onDisk) == errSecSuccess, let onDisk else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(onDisk, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let info = info as? [String: Any] else { return nil }
    return info[kSecCodeInfoTeamIdentifier as String] as? String
}

/// The running code on the other end of `fd`, by the audit token the kernel keeps for the
/// connection: a caller cannot forge it, nor be replaced by another process with its pid.
func code(of fd: Int32) -> SecCode? {
    var token = audit_token_t()
    var size = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else { return nil }
    let data = withUnsafeBytes(of: &token) { Data($0) }
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess
    else { return nil }
    return code
}

/// The signing identifier of `code` when it is valid and signed through Apple by `team`
/// (a development and a Developer ID certificate both carry the team as the leaf's OU).
func identifier(of code: SecCode, team: String, requirement: SecRequirement) -> String? {
    guard SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
    var onDisk: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &onDisk) == errSecSuccess, let onDisk else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(onDisk, [], &info) == errSecSuccess,
          let info = info as? [String: Any] else { return nil }
    return info[kSecCodeInfoIdentifier as String] as? String
}

/// The uid of the process on the other end of `fd`.
func peerUID(_ fd: Int32) -> uid_t? {
    var cred = xucred()
    var size = socklen_t(MemoryLayout<xucred>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &size) == 0 else { return nil }
    return cred.cr_uid
}

/// One byte and the descriptor it carries, or nil once the other end has gone.
func receiveDescriptor(on socket: Int32) -> Int32?? {
    var byte: UInt8 = 0
    let space = MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size + 16
    let control = UnsafeMutableRawPointer.allocate(byteCount: space, alignment: MemoryLayout<cmsghdr>.alignment)
    defer { control.deallocate() }
    return withUnsafeMutablePointer(to: &byte) { bytePointer -> Int32?? in
        var vector = iovec(iov_base: UnsafeMutableRawPointer(bytePointer), iov_len: 1)
        return withUnsafeMutablePointer(to: &vector) { vectorPointer -> Int32?? in
            var message = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: vectorPointer, msg_iovlen: 1,
                                 msg_control: control, msg_controllen: socklen_t(space), msg_flags: 0)
            let got = recvmsg(socket, &message, 0)
            if got <= 0 { return nil }
            guard message.msg_controllen >= socklen_t(MemoryLayout<cmsghdr>.size) else { return .some(nil) }
            let header = control.load(as: cmsghdr.self)
            guard header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS else { return .some(nil) }
            // CMSG_DATA: the data follows the header, aligned to 4 bytes on Darwin.
            let offset = (MemoryLayout<cmsghdr>.size + 3) & ~3
            return .some(control.load(fromByteOffset: offset, as: Int32.self))
        }
    }
}

func say(_ line: String) {
    var text = Array((line + "\n").utf8)
    var sent = 0
    while sent < text.count {
        let n = text.withUnsafeMutableBytes { write(0, $0.baseAddress! + sent, $0.count - sent) }
        if n <= 0 { exit(0) }
        sent += n
    }
}

func peers() -> Never {
    signal(SIGPIPE, SIG_IGN)
    let team = ownTeam()
    say("team \(team ?? "-")")
    var requirement: SecRequirement?
    if let team {
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        if SecRequirementCreateWithString(text as CFString, [], &requirement) != errSecSuccess { requirement = nil }
    }
    while true {
        guard let received = receiveDescriptor(on: 0) else { exit(0) }
        guard let fd = received else { say("stranger"); continue }
        defer { close(fd) }
        if peerUID(fd) != geteuid() { say("other-user"); continue }
        guard let team, let requirement, let caller = code(of: fd),
              let name = identifier(of: caller, team: team, requirement: requirement) else { say("stranger"); continue }
        say("signed \(name)")
    }
}

switch CommandLine.arguments.dropFirst().first {
case "peers": peers()
default:
    FileHandle.standardError.write(Data("usage: agents-mac peers\n".utf8))
    exit(64)
}
