#if os(Linux)
import Foundation
import LinuxControlDial

extension Daemon {
    /// `agentsd --control-code` / `--control-network` on Linux (058, T044). The same
    /// enrolment the Mac does, over BoringSSL instead of Network.framework.
    func joinWithBoringSSL(_ control: Control, server: DaemonServer, hello: DaemonAPI.HostHello) async {
        let membershipFile = locations.controlHostMembership
        do {
            let privateKey = try ControlAgreement.loadOrMake(file: locations.controlHostKey)
            var membership = ControlMembership.load(membershipFile)
            if membership == nil, let text = control.code {
                guard let code = ControlCode(text: text), case .host = code.purpose else {
                    DaemonLog.shared.write("uplink: that is not a host code")
                    return
                }
                let joined = try await Self.enrol(code, privateKey: privateKey, hello: hello)
                try joined.save(membershipFile)
                membership = joined
                DaemonLog.shared.write("uplink: enrolled with \(joined.name) as \(joined.host?.rawValue ?? "?")")
            }
            guard let membership, let host = membership.host else {
                DaemonLog.shared.write("uplink: no control plane to join; start with --control-code")
                return
            }
            let uplink = ControlUplink(server: server, hello: hello) {
                let psk = try ControlAgreement.hostKey(privateKey: privateKey, peer: membership.controlKey, host: host)
                return try await LinuxControlDial.connect(membership.addresses,
                                                          identity: ControlAgreement.hostIdentity(host), key: psk)
            }
            self.uplink = uplink
            await core.deliverNeeds { [uplink] params in uplink.tell(DaemonAPI.Method.attentionNeed, params) }
            uplink.start()
            DaemonLog.shared.write("uplink: a host of \(membership.name) over the network, as \(host.rawValue)")
        } catch {
            DaemonLog.shared.write("uplink: could not join the control plane: \(error)")
        }
    }

    private static func enrol(_ code: ControlCode, privateKey: Data,
                              hello: DaemonAPI.HostHello) async throws -> ControlMembership {
        let publicKey = try ControlAgreement.publicKey(privateKey: privateKey)
        let transport = try await LinuxControlDial.connect(
            code.addresses, identity: ControlAgreement.codeIdentity(secret: code.secret, host: true),
            key: ControlAgreement.codeKey(code.secret))
        defer { transport.close() }
        let announce = DaemonAPI.HostAnnounce(publicKey: publicKey, name: hello.name ?? "A Linux host",
                                             platform: hello.platform, version: hello.version,
                                             machineID: hello.machineID)
        let request = try JSONRPCCodec.encode(.request(id: .number(1), method: DaemonAPI.Method.hostsAnnounce,
                                                       params: try JSONValue.encoding(announce)))
        try transport.write(line: request)
        var lines = transport.lines().makeAsyncIterator()
        guard let line = try await lines.next() else {
            throw LinuxControlDial.Failure("The control plane hung up. The code may have been used or run out; ask for a new one.")
        }
        switch try JSONRPCCodec.decode(line: line) {
        case .success(_, let result):
            let admitted = try result.decode(DaemonAPI.Admitted.self)
            guard let host = admitted.host else {
                throw LinuxControlDial.Failure("The control plane did not name this host.")
            }
            return ControlMembership(host: host, controlKey: code.controlKey, addresses: code.addresses, name: code.name)
        case .failure(_, let error):
            throw LinuxControlDial.Failure(error.message)
        default:
            throw LinuxControlDial.Failure("The control plane answered something else.")
        }
    }
}
#endif
