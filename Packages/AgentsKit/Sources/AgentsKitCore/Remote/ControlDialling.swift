// Not on Linux yet: a Linux host joins over ssh until spike S1 (058, R8).
#if canImport(Network) && canImport(CryptoKit)
import CryptoKit
import Foundation
import Network

/// A client's or a host's way in to a control plane over the network (058, T022, T029):
/// once with a code, to say who it is, and from then on with its own key.
public enum ControlDialling {
    public enum Failure: Error, Sendable, CustomStringConvertible {
        case nowhereAnswered([String])
        case refused(String)

        public var description: String {
            switch self {
            case .nowhereAnswered(let addresses):
                "No control plane answered at \(addresses.joined(separator: ", ")). Is it running, and is this Mac on its network?"
            case .refused(let why): why
            }
        }
    }

    /// Pair a window (or a device) with a client code. What it may do is the code's.
    public static func pair(_ code: ControlCode, key: DeviceKey, id: UUID, name: String,
                            kind: ClientRecord.Kind) async throws -> ControlMembership {
        guard case .client = code.purpose else { throw Failure.refused("That code is for a host, not a window.") }
        let admitted = try await announce(code, method: DaemonAPI.Method.clientsAnnounce,
                                          params: DaemonAPI.ClientAnnounce(id: id, publicKey: key.publicKey,
                                                                           name: name, kind: kind))
        return ControlMembership(client: admitted.client ?? id, controlKey: code.controlKey,
                                 addresses: code.addresses, name: code.name)
    }

    /// Enrol a host with a host code. The control plane names it.
    public static func enroll(_ code: ControlCode, announce details: DaemonAPI.HostAnnounce) async throws -> ControlMembership {
        guard case .host = code.purpose else { throw Failure.refused("That code is for a window, not a host.") }
        let admitted = try await announce(code, method: DaemonAPI.Method.hostsAnnounce, params: details)
        guard let host = admitted.host else { throw Failure.refused("The control plane did not name this host.") }
        return ControlMembership(host: host, controlKey: code.controlKey, addresses: code.addresses, name: code.name)
    }

    private static func announce(_ code: ControlCode, method: String,
                                 params: some Encodable) async throws -> DaemonAPI.Admitted {
        let transport = try await connect(code.addresses, identity: ControlKeys.codeIdentity(code),
                                          key: ControlKeys.codeKey(code.secret))
        defer { transport.close() }
        let request = try JSONRPCCodec.encode(.request(id: .number(1), method: method,
                                                       params: try JSONValue.encoding(params)))
        try transport.write(line: request)
        var lines = transport.lines().makeAsyncIterator()
        guard let line = try await lines.next() else {
            throw Failure.refused("The control plane hung up. The code may have been used or run out; ask for a new one.")
        }
        switch try JSONRPCCodec.decode(line: line) {
        case .success(_, let result): return try result.decode(DaemonAPI.Admitted.self)
        case .failure(_, let error): throw Failure.refused(error.message)
        default: throw Failure.refused("The control plane answered something else.")
        }
    }

    /// How a paired window reaches its control plane, each time `ControlLink` dials.
    public static func clientDial(_ membership: ControlMembership, key: DeviceKey) -> ControlLink.Dial {
        { [membership] in
            guard let client = membership.client else { throw Failure.refused("This window is not paired.") }
            let psk = try ControlKeys.clientKey(key, peer: membership.controlKey, client: client)
            return try await connect(membership.addresses, identity: ControlKeys.clientIdentity(client), key: psk)
        }
    }

    /// How an enrolled host reaches its control plane, each time its uplink dials.
    public static func hostDial(_ membership: ControlMembership, key: DeviceKey) -> @Sendable () async throws -> any LineTransport {
        { [membership] in
            guard let host = membership.host else { throw Failure.refused("This host is not enrolled.") }
            let psk = try ControlKeys.hostKey(key, peer: membership.controlKey, host: host)
            return try await connect(membership.addresses, identity: ControlKeys.hostIdentity(host), key: psk)
        }
    }

    /// The first address that finishes the handshake.
    static func connect(_ addresses: [String], identity: String, key: SymmetricKey) async throws -> NWTransport {
        for address in addresses {
            guard let colon = address.lastIndex(of: ":"),
                  let port = NWEndpoint.Port(String(address[address.index(after: colon)...])) else { continue }
            let host = NWEndpoint.Host(String(address[..<colon]))
            let connection = NWConnection(host: host, port: port, using: LinkTLS.client(identity: identity, key: key))
            let transport = NWTransport(connection: connection)
            do {
                try await transport.waitUntilReady(timeout: .seconds(5))
                return transport
            } catch {
                transport.close()
            }
        }
        throw Failure.nowhereAnswered(addresses)
    }
}
#endif
