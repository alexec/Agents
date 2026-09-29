import AgentsKitCore
import Foundation

/// Joining a control plane over its WebSocket (058 re-plan): enrolling or pairing once with
/// a version 2 code, then dialling as oneself. `agentsd` on a Mac and on Linux, and the
/// service's tests, all go through here.
public enum ControlJoin {
    public struct Failure: Error, Sendable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// Opens a socket to `url` and proves `credentials` on it.
    public static func dial(_ url: URL, pin: String?, as credentials: ControlAuth.Credentials) async throws -> PrefixReader {
        guard let origin = ControlAuth.origin(url) else { throw Failure("\(url) is not an address to dial") }
        let socket = try await ControlDial.connect(url, pin: pin)
        return try await ControlAuth.join(socket, origin: origin, as: credentials).transport
    }

    /// Uses a version 2 code once: says who this is with `method`, and returns the reply.
    public static func announce(_ code: ControlCode, method: String, params: JSONValue) async throws -> DaemonAPI.Admitted {
        guard let text = code.url, let url = URL(string: text), let id = ControlAuth.codeID(secret: code.secret) else {
            throw Failure("that code has no address; it is from the first build")
        }
        let identity: ControlAuth.Identity = if case .host = code.purpose { .enrolling(id) } else { .pairing(id) }
        let reader = try await dial(url, pin: code.pin, as: .init(identity: identity, key: ControlAuth.codeKey(secret: code.secret),
                                                                 kind: "host", controlKey: code.controlKey))
        defer { reader.close() }
        try reader.write(line: JSONRPCCodec.encode(.request(id: .number(1), method: method, params: params)))
        guard let line = try await reader.next(within: 15) else { throw Failure("the control plane did not answer") }
        switch try JSONRPCCodec.decode(line: line) {
        case .success(_, let result): return try result.decode(DaemonAPI.Admitted.self)
        case .failure(_, let error): throw error
        default: throw Failure("the control plane answered something else: \(line)")
        }
    }

    /// A host enrols with a host code, and keeps what it needs to dial again.
    public static func enrollHost(_ code: ControlCode, privateKey: Data, hello: DaemonAPI.HostHello) async throws -> ControlMembership {
        guard case .host = code.purpose else { throw Failure("that is not a host code") }
        let announce = DaemonAPI.HostAnnounce(publicKey: try ControlAgreement.publicKey(privateKey: privateKey),
                                              name: hello.name ?? "A host", platform: hello.platform,
                                              version: hello.version, machineID: hello.machineID)
        let admitted = try await self.announce(code, method: DaemonAPI.Method.hostsAnnounce, params: try JSONValue.encoding(announce))
        guard let host = admitted.host else { throw Failure("the control plane did not say which host this is") }
        return ControlMembership(host: host, controlKey: code.controlKey, addresses: [], name: code.name,
                                 url: code.url, pin: code.pin)
    }

    /// How a host's uplink dials, every time: as itself, with its own key.
    public static func hostDial(_ membership: ControlMembership, privateKey: Data) throws -> @Sendable () async throws -> any LineTransport {
        guard let text = membership.url, let url = URL(string: text), let host = membership.host else {
            throw Failure("that membership has no address; it is from the first build")
        }
        let key = try ControlAuth.hostKey(privateKey: privateKey, peer: membership.controlKey, host: host)
        let credentials = ControlAuth.Credentials(identity: .host(host), key: key, kind: "host", controlKey: membership.controlKey)
        let pin = membership.pin
        return { try await dial(url, pin: pin, as: credentials) }
    }
}
